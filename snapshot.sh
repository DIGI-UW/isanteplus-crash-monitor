#!/usr/bin/env bash
# snapshot.sh — Capture system/JVM/MySQL state periodically
# Runs via cron alongside the main systemd crash monitor (default: every 5 min).
# Provides continuous baseline data so you can see trends leading up to crashes.
#
# Output:
#   /var/log/isanteplus-monitor/snapshots/YYYYMMDD/HHMMSS/{mem,top,gc,...}.txt
#   /var/log/isanteplus-monitor/snapshots/YYYYMMDD/metrics.csv  (one row appended)

set -euo pipefail

# Prevent concurrent runs — if a previous invocation is still compressing
# snapshots, skip this one entirely; it will be picked up next time.
LOCKFILE="/tmp/isanteplus-snapshot.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    exit 0
fi

CONFIG_FILE="${ISANTEPLUS_MONITOR_CONFIG:-/etc/isanteplus-monitor.conf}"

# Defaults
OUTPUT_DIR="/var/log/isanteplus-monitor"
TOMCAT_PATTERN="catalina.startup.Bootstrap"
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_DATABASE="openmrs"
MYSQL_HOST="localhost"
SESSION_URL="http://localhost:8080/openmrs/ws/rest/v1/session"
RETENTION_DAYS=7

if [[ -f "$CONFIG_FILE" ]]; then
    # Warn if config is world-readable (contains MySQL credentials)
    local_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null) || true
    if [[ -n "$local_perms" && "${local_perms:1:2}" != "00" ]]; then
        echo "Warning: $CONFIG_FILE is accessible by group/others (mode $local_perms). Consider chmod 600." >&2
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Add JAVA_HOME/bin to PATH if configured
if [[ -n "${JAVA_HOME:-}" && -d "${JAVA_HOME}/bin" ]]; then
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

# ── Timestamp & directories ──────────────────────────────────────────
TS_FULL=$(date +%Y%m%d_%H%M%S)
TS_DATE="${TS_FULL%%_*}"
TS_TIME="${TS_FULL##*_}"
SNAP_BASE="${OUTPUT_DIR}/snapshots"
SNAP_DIR="${SNAP_BASE}/${TS_DATE}/${TS_TIME}"
mkdir -p "$SNAP_DIR"

CSV="${SNAP_BASE}/${TS_DATE}/metrics.csv"

if [[ ! -f "$CSV" ]]; then
    echo "timestamp,heap_old_pct,mem_free_mb,mem_available_mb,load_1m,mysql_active,tomcat_pid,tomcat_rss_kb,http_status,http_time_ms" > "$CSV"
fi

# ── MySQL helper (temp cnf file, cleaned up via trap) ────────────────
# Create one temp cnf file for the entire script run, reused across queries.
MYSQL_TMP_CNF=$(mktemp /tmp/isanteplus-mysql.XXXXXX)
chmod 600 "$MYSQL_TMP_CNF"
trap 'rm -f "$MYSQL_TMP_CNF"' EXIT
{
    echo "[client]"
    echo "user=${MYSQL_USER}"
    echo "host=${MYSQL_HOST}"
    if [[ -n "$MYSQL_PASSWORD" ]]; then
        # Quote the password for the MySQL option file so special characters
        # (#, ;, \, spaces, quotes) are not interpreted.
        escaped_pw=${MYSQL_PASSWORD//\\/\\\\}
        escaped_pw=${escaped_pw//\'/\\\'}
        echo "password='${escaped_pw}'"
    fi
} > "$MYSQL_TMP_CNF"

mysql_cmd() {
    mysql --defaults-file="$MYSQL_TMP_CNF" "$MYSQL_DATABASE" "$@"
}

# ── 1. System state ──────────────────────────────────────────────────
free -m > "${SNAP_DIR}/mem.txt" 2>/dev/null || true
top -bn1 | head -20 > "${SNAP_DIR}/top.txt" 2>/dev/null || true
vmstat 1 3 > "${SNAP_DIR}/vmstat.txt" 2>/dev/null || true

mem_free_mb=""
mem_available_mb=""
if [[ -f /proc/meminfo ]]; then
    mem_free_mb=$(awk '/^MemFree:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "")
    mem_available_mb=$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "")
fi

load_1m=""
if [[ -f /proc/loadavg ]]; then
    read -r load_1m _ < /proc/loadavg 2>/dev/null || true
fi

# ── 2. JVM / Tomcat ──────────────────────────────────────────────────
PID=$(pgrep -f "$TOMCAT_PATTERN" | head -1 || true)
heap_old_pct=""
tomcat_rss_kb=""

if [[ -n "$PID" ]]; then
    jstat -gcutil "$PID" > "${SNAP_DIR}/gc.txt" 2>/dev/null || true

    # Old generation % (column 4 of gcutil) — best crash predictor
    heap_old_pct=$(awk 'NR==2 {printf "%.1f", $4}' "${SNAP_DIR}/gc.txt" 2>/dev/null || echo "")

    if [[ -f "/proc/${PID}/status" ]]; then
        grep -E '^(VmRSS|VmSize|Threads)' "/proc/${PID}/status" > "${SNAP_DIR}/jvm_proc.txt" 2>/dev/null || true
        tomcat_rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/${PID}/status" 2>/dev/null || echo "")
    fi
fi

# ── 3. MySQL state ───────────────────────────────────────────────────
mysql_active=""
mysql_cmd -e "SHOW FULL PROCESSLIST;" > "${SNAP_DIR}/mysql_procs.txt" 2>/dev/null || true
mysql_cmd -e "SHOW ENGINE INNODB STATUS\G" > "${SNAP_DIR}/innodb.txt" 2>/dev/null || true

# Count active queries via SQL (more reliable than parsing tabular output)
mysql_active=$(mysql_cmd -N -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' AND USER != 'system user'" 2>/dev/null || echo "")

# ── 4. HTTP probe ────────────────────────────────────────────────────
http_status=""
http_time_ms=""
if command -v curl &>/dev/null; then
    http_response=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --max-time 10 "$SESSION_URL" 2>/dev/null || echo "000 0")
    http_status=$(echo "$http_response" | awk '{print $1}')
    http_time_ms=$(echo "$http_response" | awk '{printf "%.0f", $2 * 1000}')
fi

# ── 5. Append to daily CSV ───────────────────────────────────────────
echo "${TS_DATE}_${TS_TIME},${heap_old_pct:-},${mem_free_mb:-},${mem_available_mb:-},${load_1m:-},${mysql_active:-},${PID:-},${tomcat_rss_kb:-},${http_status:-},${http_time_ms:-}" >> "$CSV"

# ── 6. Housekeeping ──────────────────────────────────────────────────
# Compress snapshot directories older than 1 hour
find "${SNAP_BASE}" -mindepth 2 -maxdepth 2 -type d \
    -mmin +60 \
    -exec sh -c '
        for dir; do
            base=$(basename "$dir")
            parent=$(dirname "$dir")
            ionice -c 3 nice -n 19 tar czf "${parent}/${base}.tar.gz" -C "$parent" "$base" 2>/dev/null && rm -rf "$dir"
        done
    ' _ {} + 2>/dev/null || true

# Purge old date directories
find "${SNAP_BASE}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
