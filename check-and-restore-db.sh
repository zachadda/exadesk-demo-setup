#!/usr/bin/env bash
# Verify TPCH_SF10 and TPCH_SF100 schemas are healthy.
# If degraded, restore from the latest usable S3 backup.
#
# Exit codes:
#   0 - DB healthy (initially or after restore)
#   1 - Restore failed or no usable backup found
#   2 - Unexpected error (cannot reach DB host, etc.)

set -uo pipefail

DB_HOST="${DB_HOST:-192.168.5.58}"
DB_PORT="${DB_PORT:-8563}"
COS_PORT="${COS_PORT:-20002}"
DB_USER="${DB_USER:-sys}"
DB_PASS="${DB_PASS:-Exasol123!}"
DB_NAME="${DB_NAME:-Exasol}"
MIN_BACKUP_GB="${MIN_BACKUP_GB:-1.0}"

# Exact per-table row counts captured from healthy DB on 2026-06-05.
# Format: "<SCHEMA>.<TABLE>" -> exact row count
declare -A EXPECTED_COUNTS=(
  ["TPCH_SF10.CUSTOMER"]=1500000
  ["TPCH_SF10.LINEITEM"]=59986052
  ["TPCH_SF10.NATION"]=25
  ["TPCH_SF10.ORDERS"]=15000000
  ["TPCH_SF10.PART"]=2000000
  ["TPCH_SF10.PARTSUPP"]=8000000
  ["TPCH_SF10.REGION"]=5
  ["TPCH_SF10.SUPPLIER"]=100000
  ["TPCH_SF100.CUSTOMER"]=15000000
  ["TPCH_SF100.LINEITEM"]=600037902
  ["TPCH_SF100.NATION"]=25
  ["TPCH_SF100.ORDERS"]=150000000
  ["TPCH_SF100.PART"]=20000000
  ["TPCH_SF100.PARTSUPP"]=80000000
  ["TPCH_SF100.REGION"]=10
  ["TPCH_SF100.SUPPLIER"]=2000000
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit "${2:-2}"; }

sql() {
  c4 sqlclient --user "$DB_USER" --password "$DB_PASS" \
    --connection "localhost:${DB_PORT}" --usetls --skiptlsverify \
    --query "$1" 2>&1
}

cos() {
  ssh -p "$COS_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$DB_HOST" "$@"
}

db_state() {
  cos "confd_client db_state db_name: ${DB_NAME}" 2>/dev/null | head -1 | tr -d '[:space:]'
}

build_where_clause() {
  local key schema table expected first=1
  for key in "${!EXPECTED_COUNTS[@]}"; do
    schema="${key%.*}"
    table="${key#*.}"
    expected="${EXPECTED_COUNTS[$key]}"
    if [[ $first -eq 1 ]]; then
      printf "(TABLE_SCHEMA='%s' AND TABLE_NAME='%s' AND TABLE_ROW_COUNT=%s)" "$schema" "$table" "$expected"
      first=0
    else
      printf " OR (TABLE_SCHEMA='%s' AND TABLE_NAME='%s' AND TABLE_ROW_COUNT=%s)" "$schema" "$table" "$expected"
    fi
  done
}

check_health() {
  local where total_expected="${#EXPECTED_COUNTS[@]}"
  where=$(build_where_clause)
  local result
  result=$(sql "SELECT COUNT(*) FROM EXA_ALL_TABLES WHERE ${where};")
  echo "$result" | grep -q "\"data\":\\[\\[${total_expected}\\]\\]"
}

print_schema_details() {
  local result actual_keys actual_counts schema table key expected actual
  result=$(sql "SELECT TABLE_SCHEMA||'.'||TABLE_NAME AS K, NVL(TABLE_ROW_COUNT,-1) AS R FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA IN ('TPCH_SF10','TPCH_SF100') ORDER BY TABLE_SCHEMA, TABLE_NAME;")

  # Parse columnar JSON: first column = keys, second = row counts.
  actual_keys=$(echo "$result" | grep -oP '"data":\[\K\[[^]]*\]' | head -1)
  actual_counts=$(echo "$result" | grep -oP '"data":\[\[[^]]*\],\K\[[^]]*\]' | head -1)

  # Build a "key=count" map from actual results, then compare to expected.
  declare -A ACTUAL
  if [[ -n "$actual_keys" && -n "$actual_counts" ]]; then
    local IFS=',' i=0
    local keys_arr counts_arr
    read -ra keys_arr   <<< "$(echo "$actual_keys"   | tr -d '[]"' )"
    read -ra counts_arr <<< "$(echo "$actual_counts" | tr -d '[]"' )"
    while [[ $i -lt ${#keys_arr[@]} ]]; do
      ACTUAL["${keys_arr[$i]}"]="${counts_arr[$i]}"
      i=$((i+1))
    done
  fi

  echo "  per-table check (expected vs actual):"
  local sorted_keys
  sorted_keys=$(printf '%s\n' "${!EXPECTED_COUNTS[@]}" | sort)
  while IFS= read -r key; do
    expected="${EXPECTED_COUNTS[$key]}"
    actual="${ACTUAL[$key]:-MISSING}"
    if [[ "$actual" == "$expected" ]]; then
      printf "    OK    %-26s %s\n" "$key" "$actual"
    else
      printf "    MISS  %-26s expected=%s actual=%s\n" "$key" "$expected" "$actual"
    fi
  done <<< "$sorted_keys"
}

find_latest_good_backup() {
  cos "confd_client db_backup_list db_name: ${DB_NAME}" 2>/dev/null | \
    awk -v min_gb="$MIN_BACKUP_GB" '
      function commit() {
        if (have && usable==1 && (gb+0) >= (min_gb+0) && ts > best_ts) {
          best_ts=ts; best_id=id; best_gb=gb
        }
      }
      /^- bid:/      { commit(); usable=0; gb=0; id=""; ts=""; have=1; next }
      /^  usable: true/ { usable=1 }
      /^  usage:/    { gb=$2 }
      /^  id:/       { line=$0; sub(/^  id: /, "", line); id=line }
      /^  ts:/       { line=$0; gsub(/[^0-9]/, "", line); ts=line }
      END {
        commit()
        if (best_id != "") {
          print best_id
          print best_ts > "/dev/stderr"
          print best_gb > "/dev/stderr"
        }
      }
    '
}

wait_for_state() {
  local target="$1" timeout="${2:-600}" elapsed=0 s
  while [[ $elapsed -lt $timeout ]]; do
    s=$(db_state)
    if [[ "$s" == "$target" ]]; then
      return 0
    fi
    log "  state='${s:-?}', waiting for '$target' (${elapsed}s/${timeout}s)..."
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

restore_from_backup() {
  local backup_id="$1" state
  state=$(db_state)
  log "Current DB state: $state"

  if [[ "$state" == "running" ]]; then
    log "Stopping database..."
    cos "confd_client db_stop db_name: ${DB_NAME}" >/dev/null 2>&1 || \
      die "db_stop failed" 1
    log "Waiting for 'setup' state (max 5min)..."
    wait_for_state "setup" 300 || die "DB did not reach setup state in time" 1
  elif [[ "$state" != "setup" ]]; then
    log "WARNING: DB in unexpected state '$state'. Attempting restore anyway."
  fi

  log "Starting restore from: $backup_id"
  log "  (downloading ~30 GiB from S3; expect 10-30+ minutes)"
  local restore_json
  restore_json=$(printf '{"backup_id":"%s","db_name":"%s","restore_type":"blocking"}' \
    "$backup_id" "$DB_NAME")
  if ! cos "confd_client db_restore -A '${restore_json}'" 2>&1; then
    die "db_restore failed" 1
  fi
  log "Restore complete."

  log "Starting database..."
  cos "confd_client db_start db_name: ${DB_NAME}" >/dev/null 2>&1 || \
    die "db_start failed" 1
  log "Waiting for 'running' state (max 10min)..."
  wait_for_state "running" 600 || die "DB did not reach running state in time" 1
}

wait_for_cos_reachable() {
  local timeout="${1:-180}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if cos "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    log "  COS not reachable yet (${elapsed}s/${timeout}s)..."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  return 1
}

main() {
  log "==> DB health check starting"

  # Boot-safe: wait for COS to be reachable (handles boot scenarios)
  wait_for_cos_reachable 180 || die "Cannot reach $DB_HOST:$COS_PORT after 3min" 2

  local state
  state=$(db_state)
  log "DB state: ${state:-unknown}"

  # If DB isn't running, try a normal start first — never restore without
  # actually confirming the data is gone.
  if [[ "$state" != "running" ]]; then
    log "==> DB not running. Attempting db_start before any restore decision..."
    cos "confd_client db_start db_name: ${DB_NAME}" >/dev/null 2>&1 || \
      log "  db_start returned non-zero (may already be transitioning)"
    wait_for_state "running" 300 || log "  Did not reach 'running' in 5min"
    state=$(db_state)
    log "  DB state now: ${state:-unknown}"
  fi

  # If still not running, the DB is genuinely broken — restore is justified.
  # If running, verify health by querying schemas.
  if [[ "$state" == "running" ]]; then
    if check_health; then
      log "==> HEALTHY: TPCH_SF10 and TPCH_SF100 verified."
      print_schema_details
      exit 0
    fi
    log "==> UNHEALTHY: schemas missing or row counts below threshold."
    print_schema_details
  else
    log "==> DB will not start (state=$state). Restore is justified."
  fi

  log "==> Selecting latest usable backup (>= ${MIN_BACKUP_GB} GiB)..."
  local backup_id
  backup_id=$(find_latest_good_backup 2>/dev/null)
  if [[ -z "$backup_id" ]]; then
    die "No usable backup found (>= ${MIN_BACKUP_GB} GiB)" 1
  fi
  log "  Selected backup_id: $backup_id"

  restore_from_backup "$backup_id"

  log "==> Re-verifying health post-restore..."
  if check_health; then
    log "==> RESTORE SUCCESSFUL: schemas verified."
    print_schema_details
    exit 0
  fi
  die "Health check still failing after restore" 1
}

main "$@"
