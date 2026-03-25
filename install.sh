#!/usr/bin/env bash
# install.sh — Deploy isanteplus-crash-monitor
# Run as root: sudo ./install.sh

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo $0)" >&2
    exit 1
fi

echo "=== iSantePlus Monitor — Install ==="
echo ""

# ── Check prerequisites ──────────────────────────────────────────────
for cmd in bash curl mysql; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "WARNING: $cmd not found — some features will be limited"
    fi
done

if ! command -v jstat &>/dev/null; then
    echo "WARNING: jstat not in PATH — install a JDK (not just JRE) for JVM monitoring"
    echo "  Set JAVA_HOME in /etc/isanteplus-monitor.conf after install"
fi
echo ""

# ── Install scripts ──────────────────────────────────────────────────
cp "${SOURCE_DIR}/isanteplus-monitor.sh" /usr/local/bin/isanteplus-monitor.sh
cp "${SOURCE_DIR}/snapshot.sh" /usr/local/bin/isanteplus-snapshot.sh
cp "${SOURCE_DIR}/analyze.sh" /usr/local/bin/isanteplus-analyze.sh
chmod +x /usr/local/bin/isanteplus-monitor.sh
chmod +x /usr/local/bin/isanteplus-snapshot.sh
chmod +x /usr/local/bin/isanteplus-analyze.sh
echo "Scripts installed to /usr/local/bin/"

# ── Install config (don't overwrite existing) ────────────────────────
if [[ ! -f /etc/isanteplus-monitor.conf ]]; then
    cp "${SOURCE_DIR}/isanteplus-monitor.conf" /etc/isanteplus-monitor.conf
    chmod 600 /etc/isanteplus-monitor.conf
    echo "Config installed: /etc/isanteplus-monitor.conf"
    echo "  >>> Edit this file to set MySQL password and paths! <<<"
else
    echo "Config already exists — not overwriting: /etc/isanteplus-monitor.conf"
fi

# ── Install systemd service ──────────────────────────────────────────
cp "${SOURCE_DIR}/isanteplus-monitor.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable isanteplus-monitor.service
echo "Systemd service installed and enabled"

# ── Create log directory ─────────────────────────────────────────────
mkdir -p /var/log/isanteplus-monitor/{incidents,snapshots}
echo "Log directory created: /var/log/isanteplus-monitor/"

# ── Install cron for continuous snapshots ────────────────────────────
cat > /etc/cron.d/isanteplus-snapshot << 'EOF'
# iSantePlus continuous monitoring — captures system/JVM/MySQL state every minute
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/local/bin/isanteplus-snapshot.sh >> /var/log/isanteplus-monitor/snapshot-cron.log 2>&1
EOF
chmod 644 /etc/cron.d/isanteplus-snapshot
echo "Cron job installed: /etc/cron.d/isanteplus-snapshot"

echo ""
echo "=== Install complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit config:         vi /etc/isanteplus-monitor.conf"
echo "  2. Start crash monitor: systemctl start isanteplus-monitor"
echo "  3. Check status:        systemctl status isanteplus-monitor"
echo "  4. View incidents:      isanteplus-analyze.sh --list"
echo "  5. Snapshots start automatically via cron (every minute)"
