#!/usr/bin/env bash
# uninstall.sh — Remove isanteplus-crash-monitor
# Run as root: sudo ./uninstall.sh
#
# Removes scripts, config, systemd service, and cron job.
# Log directory (/var/log/isanteplus-monitor/) is preserved.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo $0)" >&2
    exit 1
fi

echo "=== iSantePlus Monitor — Uninstall ==="
echo ""

# ── Stop and disable systemd service ─────────────────────────────────
if systemctl is-active --quiet isanteplus-monitor.service 2>/dev/null; then
    systemctl stop isanteplus-monitor.service
    echo "Stopped isanteplus-monitor service"
fi
if systemctl is-enabled --quiet isanteplus-monitor.service 2>/dev/null; then
    systemctl disable isanteplus-monitor.service
    echo "Disabled isanteplus-monitor service"
fi
rm -f /etc/systemd/system/isanteplus-monitor.service
systemctl daemon-reload
echo "Removed systemd service"

# ── Remove cron job ──────────────────────────────────────────────────
rm -f /etc/cron.d/isanteplus-snapshot
echo "Removed cron job"

# ── Remove scripts ───────────────────────────────────────────────────
rm -f /usr/local/bin/isanteplus-monitor.sh
rm -f /usr/local/bin/isanteplus-snapshot.sh
rm -f /usr/local/bin/isanteplus-analyze.sh
echo "Removed scripts from /usr/local/bin/"

# ── Remove config ────────────────────────────────────────────────────
rm -f /etc/isanteplus-monitor.conf
echo "Removed config: /etc/isanteplus-monitor.conf"

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "Log directory preserved: /var/log/isanteplus-monitor/"
echo "Remove it manually if no longer needed:"
echo "  rm -rf /var/log/isanteplus-monitor/"
