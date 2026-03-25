# iSantePlus Crash Monitor

Monitoring toolkit for iSantePlus production servers. Two components:

1. **Crash monitor** (`isanteplus-monitor.sh`) — systemd service that polls the OpenMRS REST endpoint every 15 seconds. On failure: captures diagnostics (thread dumps, GC stats, MySQL state, InnoDB status), optionally restarts Tomcat.

2. **Continuous snapshots** (`snapshot.sh`) — cron job that captures system/JVM/MySQL state every minute into a metrics CSV. Provides baseline data so you can see the trend *leading up to* a crash.

Both components share the same config file.

## Quick Start

```bash
# Clone and install
git clone https://github.com/ibacher/isanteplus-crash-monitor.git
cd isanteplus-crash-monitor
sudo ./install.sh

# Edit config (set MySQL password, paths)
sudo vi /etc/isanteplus-monitor.conf

# Start the crash monitor
sudo systemctl start isanteplus-monitor

# Snapshots start automatically via cron
```

## What Gets Captured

### On every crash (systemd monitor)
- OpenMRS application log
- System state: memory, processes, disk, vmstat
- JVM: thread dump (`jstack`), GC stats (`jstat`), heap histogram, process info
- MySQL: InnoDB status, full process list, active transactions, lock waits
- Optional: full heap dump (`jmap -dump`) — disabled by default (produces 1-2GB files)

### Every minute (cron snapshots)
- System: `free`, `top`, `vmstat`
- JVM: GC utilization (`jstat -gcutil`), RSS, thread count
- MySQL: process list, InnoDB status
- HTTP health probe (status code + response time)
- **Metrics CSV**: one-line summary per minute for fast time-series scanning

## Post-Crash Analysis

```bash
# List recent incidents
isanteplus-analyze.sh --list

# Analyze the latest incident (thread states, deadlocks, GC, MySQL)
isanteplus-analyze.sh

# Analyze a specific incident
isanteplus-analyze.sh 2026-03-25T14:30:00

# View metrics CSV for a date (shows trends leading up to crash)
isanteplus-analyze.sh --csv 20260325
```

## Configuration

Config file: `/etc/isanteplus-monitor.conf`

| Setting | Default | Description |
|---------|---------|-------------|
| `SESSION_URL` | `http://localhost:8080/openmrs/ws/rest/v1/session` | URL to health-check |
| `TIMEOUT` | `15` | HTTP timeout (seconds) |
| `POLL_INTERVAL` | `15` | Seconds between health checks |
| `RESTART_TOMCAT` | `true` | Auto-restart on crash |
| `ENABLE_HEAP_DUMP` | `false` | Capture full heap dump (large!) |
| `RETENTION_DAYS` | `7` | Days to keep old data |
| `MYSQL_USER` | `root` | MySQL user |
| `MYSQL_PASSWORD` | (empty) | MySQL password |

## File Layout

```
/usr/local/bin/
  isanteplus-monitor.sh    # Crash detection daemon
  isanteplus-snapshot.sh   # Per-minute state capture
  isanteplus-analyze.sh    # Post-crash forensics

/etc/
  isanteplus-monitor.conf  # Configuration (chmod 600)
  cron.d/isanteplus-snapshot  # Cron entry for snapshots

/etc/systemd/system/
  isanteplus-monitor.service  # Systemd unit

/var/log/isanteplus-monitor/
  incidents/               # Crash diagnostics (per-incident directories)
  snapshots/               # Continuous snapshots (per-day directories)
    YYYYMMDD/
      metrics.csv          # Daily time-series (fast scan)
      HHMMSS/              # Per-minute snapshot files
```

## Housekeeping

Both scripts automatically:
- Compress snapshot directories older than 1 hour
- Purge data older than `RETENTION_DAYS` (default: 7)

## Uninstall

```bash
sudo systemctl stop isanteplus-monitor
sudo systemctl disable isanteplus-monitor
sudo rm -f /etc/systemd/system/isanteplus-monitor.service
sudo rm -f /etc/cron.d/isanteplus-snapshot
sudo rm -f /usr/local/bin/isanteplus-{monitor,snapshot,analyze}.sh
sudo rm -f /etc/isanteplus-monitor.conf
# Logs preserved at /var/log/isanteplus-monitor/ — delete manually if desired
```
