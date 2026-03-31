# EXADesk

An Exasol 2025.2.1 database running on a Minisforum mini PC — lovingly named **EXADesk**. Built for price-performance demos, proving you don't need a rack of servers or an expensive cloud compute database to run a high-performance analytical database.

## What is this?

EXADesk is a single-node Exasol deployment running on consumer desktop hardware. It's designed to show what Exasol can do on modest hardware — perfect for demos, benchmarks, and proof-of-concept work.

## Hardware Specs

| Component | Spec |
|-----------|------|
| **Machine** | Minisforum EliteMini Series |
| **CPU** | AMD Ryzen 9 8945HS — 8 cores / 16 threads @ up to 5.26 GHz |
| **RAM** | 64 GB DDR5 |
| **Storage** | 1 TB Kingston NVMe SSD |
| **GPU** | AMD Radeon 780M (integrated) |
| **Form Factor** | Mini PC (~5" x 5" x 2") |

## Software

| Component | Version |
|-----------|---------|
| **Exasol** | 2025.2.1 |
| **c4** | 4.29.0 |
| **OS** | Ubuntu 22.04.5 LTS |

## Disk Layout

| Partition | Size | Purpose |
|-----------|------|---------|
| nvme0n1p2 | 100 GB | OS (Ubuntu) |
| nvme0n1p3 | 231 GB | Exasol data |
| nvme0n1p4 | 231 GB | Exasol data |
| nvme0n1p5 | 231 GB | Exasol data |
| nvme0n1p6 | 231 GB | Exasol data |

**Total Exasol storage: ~860 GB across 4 raw NVMe partitions**

## Network Architecture

EXADesk sits on a home network behind CGNAT. Remote access is provided through a Tailscale VPN mesh and an EC2 HAProxy relay:

```
Internet / Work Laptop
        |
        | Public internet
        |
EC2 (HAProxy relay) ── Frankfurt
        |
        | Tailscale (WireGuard encrypted)
        |
EXADesk (Minisforum) ── Home network
        |
Exasol 2025.2.1
```

See [NETWORK_SETUP.md](NETWORK_SETUP.md) for full details.

## Access

| Service | Local | Remote (via EC2) |
|---------|-------|-----------------|
| Database (JDBC) | `192.168.5.59:8563` | `52.28.97.243:8563` |
| Admin UI | `https://192.168.5.59:8443` | `https://52.28.97.243:8443` |
| Admin API | `192.168.5.59:4444` | `52.28.97.243:4444` |
| BucketFS | `192.168.5.59:2580-2581` | `52.28.97.243:2580-2581` |

JDBC connection string:
```
jdbc:exa:52.28.97.243:8563
```

## What's in this repo?

| File | Description |
|------|-------------|
| `install.sh` | Automated Exasol install script — handles disk prep, deployment, c4 upgrade, and Admin UI setup |
| `config` | c4 deployment configuration |
| `haproxy.cfg` | HAProxy config running on EC2 for remote access relay |
| `NETWORK_SETUP.md` | Detailed network architecture and troubleshooting guide |
| `setup.sh` | Original setup script |
| `ubuntu-c4.sh` | EC2 SSH reference |

## Quick Start

### Fresh install
```bash
# Place exasol-2025.2.1.tar.gz in ~/
sudo bash install.sh
```

### Connect from anywhere
```bash
# JDBC
jdbc:exa:52.28.97.243:8563

# Admin UI
https://52.28.97.243:8443
```

## Why EXADesk?

- **Price**: A Minisforum with these specs costs ~$600-800. Compare that to cloud compute costs for 8 cores and 64 GB RAM running 24/7.
- **Performance**: NVMe SSD + 8-core Zen 4 + 64 GB RAM is more than enough to crunch through analytical workloads and TPC-H benchmarks.
- **Simplicity**: One box, one script, fully automated install. No cluster management overhead.
- **Portability**: Small enough to carry to a demo. Runs anywhere with a power outlet and WiFi.
