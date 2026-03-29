# Exasol Network Setup — Secure Remote Access via Tailscale + HAProxy

## Overview

Exasol 2025.2.1 runs on a Minisforum machine on a home network. Remote access is provided through a Tailscale VPN mesh connecting the Minisforum to an EC2 instance in AWS Frankfurt. HAProxy on EC2 relays traffic from the public internet to Exasol through the encrypted Tailscale tunnel.

The database is never directly exposed to the public internet.

## Architecture

```
Internet / Work Laptop
        |
        | Public internet (TCP)
        |
EC2 t3.small (52.28.97.243) — Frankfurt
  ├── HAProxy (ports 8563, 8443, 4444, 2580, 2581)
  └── Tailscale (100.124.156.17)
        |
        | WireGuard encrypted tunnel
        |
Minisforum (192.168.5.58 LAN / 100.117.230.47 Tailscale)
  ├── Exasol 2025.2.1 (c4 4.29.0)
  ├── Admin UI (port 8443)
  ├── Tailscale
  └── UFW firewall (deny all except SSH + tailscale0)
```

## Connection Details

### From the public internet (via EC2 relay)
| Service | Address | Protocol |
|---------|---------|----------|
| Database | `52.28.97.243:8563` | JDBC/SQL |
| Admin UI | `https://52.28.97.243:8443` | HTTPS |
| Admin API | `52.28.97.243:4444` | HTTPS |
| BucketFS | `52.28.97.243:2580` | HTTPS |
| BucketFS | `52.28.97.243:2581` | HTTPS |

### From Tailscale network (direct)
| Service | Address | Protocol |
|---------|---------|----------|
| Database | `100.117.230.47:8563` | JDBC/SQL |
| Admin UI | `https://100.117.230.47:8443` | HTTPS |

### From home LAN (direct)
| Service | Address | Protocol |
|---------|---------|----------|
| Database | `192.168.5.58:8563` | JDBC/SQL |
| Admin UI | `https://192.168.5.58:8443` | HTTPS |

### Credentials
- **Database:** user `sys` / password `Exasol123!`
- **Admin UI:** user `admin` / password `Exasol123!`

---

## Component Details

### 1. Minisforum (Exasol Host)

**OS:** Ubuntu (XFS root)
**Disk:** Kingston NVMe 1TB
- `/dev/nvme0n1p2` — 100GB OS
- `/dev/nvme0n1p3-p6` — 4x 231GB Exasol data

**Network:**
- LAN IP: `192.168.5.58` (DHCP reservation on Eero router, MAC `c4:8b:66:54:37:cb`)
- Tailscale IP: `100.117.230.47`

**Firewall (UFW):**
```bash
sudo ufw default deny incoming
sudo ufw allow ssh
sudo ufw allow in on tailscale0
sudo ufw enable
```

**Services:**
- `c4.service` — Exasol c4 server
- `c4_cloud_command.service` — Exasol deployment manager (depends on `network-online.target`)
- `exasol-admin-ui.service` — Admin UI (uses bundled c4 4.29.0)
- `tailscaled.service` — Tailscale daemon

### 2. EC2 Instance (HAProxy Relay)

**Instance:** t3.small, eu-central-1 (Frankfurt)
**Public IP:** `52.28.97.243`
**Tailscale IP:** `100.124.156.17`
**Security Group:** `launch-wizard-15`

**SSH Access:**
```bash
ssh -i ~/zaad-frankfurt-keypair-pem.pem ubuntu@ec2-52-28-97-243.eu-central-1.compute.amazonaws.com
```

**HAProxy Config** (`/etc/haproxy/haproxy.cfg`):
```
global
    log /dev/log local0
    maxconn 256

defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h

frontend exasol_db
    bind *:8563
    default_backend exasol_db_backend

backend exasol_db_backend
    server minisforum 100.117.230.47:8563 check

frontend exasol_adminui
    bind *:8443
    default_backend adminui_backend

backend adminui_backend
    server minisforum 100.117.230.47:8443 check

frontend exasol_admin_api
    bind *:4444
    default_backend admin_api_backend

backend admin_api_backend
    server minisforum 100.117.230.47:4444 check

frontend exasol_bucketfs
    bind *:2580
    default_backend bucketfs_backend

backend bucketfs_backend
    server minisforum 100.117.230.47:2580 check

frontend exasol_bucketfs2
    bind *:2581
    default_backend bucketfs2_backend

backend bucketfs2_backend
    server minisforum 100.117.230.47:2581 check
```

**Security Group Inbound Rules:**
| Port | Protocol | Source |
|------|----------|--------|
| 22 | TCP | Your IP |
| 8563 | TCP | `0.0.0.0/0` |
| 8443 | TCP | `0.0.0.0/0` |
| 4444 | TCP | `0.0.0.0/0` |
| 2580 | TCP | `0.0.0.0/0` |
| 2581 | TCP | `0.0.0.0/0` |

### 3. Tailscale Network

**Account:** zach.adda@
**Plan:** Free (up to 100 devices, 3 users)

| Device | Tailscale IP | Hostname |
|--------|-------------|----------|
| Minisforum | 100.117.230.47 | mrexasol |
| EC2 | 100.124.156.17 | ip-172-31-24-19 |

Tailscale IPs are stable and don't change when the underlying network changes.

---

## Why This Architecture

### ISP is behind CGNAT
The home ISP uses Carrier-Grade NAT (CGNAT). The Eero router gets a `100.66.x.x` address, not a real public IP. Port forwarding on the Eero only works from within the same ISP network — not from the general internet. Tailscale solves this by making outbound connections that punch through NAT.

### No public database exposure
Exasol listens only on the LAN and Tailscale interfaces. UFW blocks all incoming traffic except SSH and Tailscale. The only way to reach the database from the internet is through the EC2 HAProxy relay.

### Work laptop can't install Tailscale
IT restrictions prevent installing Tailscale on the work laptop. The EC2 HAProxy relay provides a public endpoint that any device can connect to without special software.

---

## Troubleshooting

### Database not accessible after reboot
`c4_cloud_command` may fail to start if the network isn't ready. Check:
```bash
sudo systemctl status c4_cloud_command
sudo journalctl -u c4_cloud_command -n 20
```
Fix: restart the service once the network is up:
```bash
sudo systemctl restart c4_cloud_command
```

### Verify database is running
```bash
nc -zv 192.168.5.58 8563
# or check DWAd log:
sudo tail ~/.ccc/play/local/*/main/11/data/logs/logd/DWAd.log
```
Note: `c4 ps` may show stage `a1` even when the DB is running. This is a display quirk.

### Verify Tailscale connectivity (from EC2)
```bash
tailscale status
tailscale ping mrexasol
nc -zv 100.117.230.47 8563
```

### Verify HAProxy (from anywhere)
```bash
nc -zv 52.28.97.243 8563
nc -zv 52.28.97.243 8443
```

### Admin UI shows "Something went wrong"
Restart the Admin UI service:
```bash
sudo systemctl restart exasol-admin-ui
```
If the issue persists, check that the c4 socket symlink exists:
```bash
ls -la ~/.ccc/x/u/branchr/ccc+*/etc/c4_socket
```

---

## Setup from Scratch

### Minisforum
1. Run `install.sh` (installs Exasol, Admin UI, upgrades c4)
2. Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
3. Configure UFW:
   ```bash
   sudo ufw default deny incoming
   sudo ufw allow ssh
   sudo ufw allow in on tailscale0
   sudo ufw enable
   ```

### EC2
1. Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
2. Authenticate to the same Tailscale account
3. Install HAProxy: `sudo apt-get install -y haproxy`
4. Write HAProxy config (see above) to `/etc/haproxy/haproxy.cfg`
5. Restart HAProxy: `sudo systemctl restart haproxy`
6. Open ports 8563, 8443, 4444, 2580, 2581 in EC2 security group
