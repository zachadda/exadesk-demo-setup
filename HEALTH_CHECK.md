# DB Health Check & Auto-Restore

Automated recovery system for EXADesk. Verifies that the demo TPC-H schemas are intact and restores from the latest S3 backup if data is missing.

## Why this exists

On 2026-06-03, all user schemas were lost from the Exasol database with no audit trail of what happened. The S3 backups were intact and the restore worked — but the gap between data loss and detection cost ~2 days.

This automation cuts detection latency to ≤ 1 hour and turns recovery into a hands-off process triggered automatically when schema state degrades.

## What it does

A systemd timer fires the health check **3 minutes after boot** and **every hour** thereafter. On each run, the script:

1. SSHes to COS (port 20002) and waits up to 3 minutes for it to be reachable — handles boot races where the DB stack isn't ready yet.
2. Reads `confd_client db_state`. If the DB isn't `running`, runs `db_start` and waits up to 5 minutes for it to come up.
3. Once the DB is running, queries `EXA_ALL_TABLES` and verifies **all 16 expected TPC-H tables exist with exact row counts**:

   | Schema | Tables | Total rows |
   |---|---|---|
   | `TPCH_SF10` | REGION (5), NATION (25), SUPPLIER (100K), CUSTOMER (1.5M), PART (2M), PARTSUPP (8M), ORDERS (15M), LINEITEM (59,986,052) | ~86.6M |
   | `TPCH_SF100` | REGION (10), NATION (25), SUPPLIER (2M), CUSTOMER (15M), PART (20M), PARTSUPP (80M), ORDERS (150M), LINEITEM (600,037,902) | ~867M |

4. If **any** table is missing or any row count differs from expected, the script:
   - Selects the most recent backup with `usable: true` and usage ≥ 1 GiB (skips the 0.001 GiB "empty" backups that follow a data-loss event)
   - Runs `db_stop`, waits for `setup` state
   - Runs `db_restore` (blocking — downloads ~30 GiB from S3, ~10–30 min)
   - Runs `db_start`, waits for `running`
   - Re-verifies and exits

5. Exits with `0` if healthy (initial or post-restore), `1` if restore failed / no backup, `2` if the DB host is unreachable.

## Files

| File | Path | Purpose |
|---|---|---|
| Script | `/home/mrexasol/check-and-restore-db.sh` | The health check + restore logic |
| Service unit | `/etc/systemd/system/db-health-check.service` | `Type=oneshot`, runs the script as `mrexasol` |
| Timer unit | `/etc/systemd/system/db-health-check.timer` | `OnBootSec=3min`, `OnUnitActiveSec=1h` |

Copies of the systemd units are in [`systemd/`](systemd/) in this repo.

## Install on a fresh machine

```bash
# 1. Copy script to /home/mrexasol/ and make executable
cp check-and-restore-db.sh /home/mrexasol/
chmod +x /home/mrexasol/check-and-restore-db.sh

# 2. Install systemd units
sudo cp systemd/db-health-check.service /etc/systemd/system/
sudo cp systemd/db-health-check.timer /etc/systemd/system/

# 3. Reload + enable the timer (service runs via timer, no need to enable directly)
sudo systemctl daemon-reload
sudo systemctl enable --now db-health-check.timer
```

## Operate

```bash
# See the most recent run output
sudo journalctl -u db-health-check.service -n 50

# See when it will fire next
systemctl list-timers db-health-check.timer

# Run the check manually right now
sudo systemctl start db-health-check.service

# Disable it (e.g. during a planned manual restore)
sudo systemctl disable --now db-health-check.timer

# Re-enable it
sudo systemctl enable --now db-health-check.timer
```

## Tuning

All thresholds are env-var overrideable — set them in the service file's `[Service]` section as `Environment=KEY=value`:

| Env var | Default | Purpose |
|---|---|---|
| `MIN_BACKUP_GB` | `1.0` | Skip backups below this size (filters out empty post-loss backups) |
| `DB_HOST`, `DB_PORT`, `COS_PORT` | `192.168.5.58`, `8563`, `20002` | Connection targets |
| `DB_NAME` | `Exasol` | Database name |
| `DB_USER`, `DB_PASS` | `sys`, `Exasol123!` | DB credentials |

The expected per-table row counts are hardcoded in an associative array near the top of the script (`EXPECTED_COUNTS`). If you regenerate the TPC-H data and the counts change, update that array.

## When you intentionally want to change the data

The auto-restore will fight you if you intentionally modify the demo schemas, because next time the timer fires it'll see the row counts don't match expected and trigger a restore.

Two options:

1. **Disable the timer** while you work:
   ```bash
   sudo systemctl disable --now db-health-check.timer
   # ...do your work...
   sudo systemctl enable --now db-health-check.timer  # when done
   ```

2. **Update `EXPECTED_COUNTS`** in the script to match the new state, so the new state becomes the "healthy" baseline.

## Backup dependency

This relies on the S3 backup schedule documented in the c4 deployment: daily 02:00 full backup to `s3://zaad-exadesk-backups/` (us-east-2), 7-day retention. If backups stop working, the auto-restore has nothing to restore from. The script logs to journal which backup it selected — that's the canary for backup health too.
