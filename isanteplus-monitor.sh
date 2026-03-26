#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${ISANTEPLUS_MONITOR_CONFIG:-/etc/isanteplus-monitor.conf}"

# Defaults (overridden by config file)
SESSION_URL="http://localhost:8080/openmrs/ws/rest/v1/session"
TIMEOUT=15
POLL_INTERVAL=15
OUTPUT_DIR="/var/log/isanteplus-monitor/"
OPENMRS_LOG="/usr/share/tomcat7/.OpenMRS/openmrs.log"
RESTART_TOMCAT=true
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_DATABASE="openmrs"
MYSQL_HOST="localhost"
RETENTION_DAYS=7
ENABLE_HEAP_DUMP=false
TOMCAT_PATTERN="catalina.startup.Bootstrap"

# Max time to wait for Tomcat to come back after a restart (in seconds)
RESTART_TIMEOUT=300

# Housekeeping throttle: only run once per hour
_LAST_HOUSEKEEPING=0

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Warn if the config file is readable by group or others, since it
        # contains MySQL credentials
        local perms
        perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null) || true
        if [[ -n "$perms" && "${perms:1:2}" != "00" ]]; then
            echo "Warning: $CONFIG_FILE is accessible by group/others (mode $perms). Consider chmod 600." >&2
        fi

        # Source config file, which overwrites the defaults above
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo "Warning: config file $CONFIG_FILE not found, using defaults" >&2
    fi
}

find_tomcat_pid() {
    pgrep -f "$TOMCAT_PATTERN" | head -n 1 || true
}

# Write a temporary MySQL option file and pass it to mysql via
# --defaults-extra-file so the password never appears in the process table.
# One temp file is created after config load and reused across all calls.
MYSQL_TMP_CNF=""

setup_mysql_cnf() {
    MYSQL_TMP_CNF=$(mktemp /tmp/isanteplus-mysql.XXXXXX)
    chmod 600 "$MYSQL_TMP_CNF"
    trap 'rm -f "$MYSQL_TMP_CNF"' EXIT

    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "host=${MYSQL_HOST}"
        if [[ -n "$MYSQL_PASSWORD" ]]; then
            echo "password=${MYSQL_PASSWORD}"
        fi
    } > "$MYSQL_TMP_CNF"
}

mysql_cmd() {
    mysql --defaults-extra-file="$MYSQL_TMP_CNF" "$MYSQL_DATABASE" "$@"
}

collect_diagnostics() {
    local timestamp
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
    local incident_dir="${OUTPUT_DIR}/incidents/${timestamp}"

    mkdir -p "$incident_dir"
    echo "Collecting diagnostics in $incident_dir"

    # 1. Copy OpenMRS log
    if [[ -f "$OPENMRS_LOG" ]]; then
        cp "$OPENMRS_LOG" "${incident_dir}/openmrs.log"
        echo "  Copied openmrs.log"
    else
        echo "  Warning: $OPENMRS_LOG not found" >&2
    fi

    # 2. System state
    free -m > "${incident_dir}/memory.txt" 2>/dev/null || true
    uptime > "${incident_dir}/uptime.txt" 2>/dev/null || true
    vmstat 1 3 > "${incident_dir}/vmstat.txt" 2>/dev/null || true
    df -h > "${incident_dir}/disk.txt" 2>/dev/null || true
    echo "  Captured system state"

    # 3. Process listing (CPU-sorted)
    ps aux --sort=-%cpu > "${incident_dir}/ps_aux.txt" 2>&1 || true
    echo "  Captured process listing"

    # 4. InnoDB status
    if mysql_cmd -e "SHOW ENGINE INNODB STATUS\G" > "${incident_dir}/innodb_status.txt" 2>&1; then
        echo "  Captured InnoDB status"
    else
        echo "  Warning: failed to capture InnoDB status" >&2
    fi

    # 5. Full process list
    if mysql_cmd -e "SHOW FULL PROCESSLIST\G" > "${incident_dir}/processlist.txt" 2>&1; then
        echo "  Captured MySQL process list"
    else
        echo "  Warning: failed to capture MySQL process list" >&2
    fi

    # 6. Active transactions and lock waits
    mysql_cmd -e "SELECT * FROM information_schema.INNODB_TRX\G" > "${incident_dir}/active_trx.txt" 2>/dev/null || true
    # INNODB_LOCK_WAITS exists in MySQL 5.x; data_lock_waits is MySQL 8.0+ only
    mysql_cmd -e "SELECT * FROM information_schema.INNODB_LOCK_WAITS\G" > "${incident_dir}/lock_waits.txt" 2>/dev/null || true

    # 7. JVM diagnostics
    local tomcat_pid
    tomcat_pid=$(find_tomcat_pid)
    if [[ -n "$tomcat_pid" ]]; then
        # GC statistics (lightweight — reads from JVM shared memory)
        jstat -gcutil "$tomcat_pid" > "${incident_dir}/gc_stats.txt" 2>/dev/null || true
        jstat -gccapacity "$tomcat_pid" > "${incident_dir}/gc_capacity.txt" 2>/dev/null || true
        echo "  Captured GC statistics for PID $tomcat_pid"

        # Thread dump (much lighter than heap dump, shows deadlocks)
        if timeout 30 jstack "$tomcat_pid" > "${incident_dir}/threads.txt" 2>&1; then
            echo "  Captured thread dump for PID $tomcat_pid"
        else
            echo "  Warning: jstack failed for PID $tomcat_pid" >&2
        fi

        # Heap dump (optional — produces large files, 1-2GB)
        # -J-d64 is required for JDK 8's 64-bit JVM
        if [[ "${ENABLE_HEAP_DUMP}" == "true" ]]; then
            if jmap -J-d64 -dump:format=b,file="${incident_dir}/heap.hprof" "$tomcat_pid" 2>&1; then
                echo "  Captured heap dump for PID $tomcat_pid"
            else
                echo "  Warning: jmap heap dump failed for PID $tomcat_pid" >&2
            fi
        fi

        # Object histogram (lighter alternative to full heap dump)
        # -J-d64 is required for JDK 8's 64-bit JVM
        timeout 60 jmap -J-d64 -histo "$tomcat_pid" | head -50 > "${incident_dir}/heap_histo.txt" 2>/dev/null || true

        # Process info from /proc
        if [[ -f "/proc/${tomcat_pid}/status" ]]; then
            grep -E '^(VmRSS|VmSize|Threads)' "/proc/${tomcat_pid}/status" > "${incident_dir}/jvm_proc.txt" 2>/dev/null || true
        fi
    else
        echo "  Warning: could not find Tomcat PID for JVM diagnostics" >&2
    fi

    echo "Diagnostics collection complete: $incident_dir"
}

restart_tomcat() {
    echo "Restarting Tomcat7..."
    if systemctl restart tomcat7 2>&1; then
        echo "Tomcat7 restart issued"
    else
        echo "Warning: failed to restart Tomcat7" >&2
    fi
}

wait_for_new_pid() {
    local old_pid="$1"
    local waited=0

    echo "Waiting for Tomcat7 to restart (old PID: ${old_pid:-none})..."

    while true; do
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))

        local new_pid
        new_pid=$(find_tomcat_pid)
        if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]]; then
            echo "Tomcat7 restarted with new PID: $new_pid"
            return
        fi

        if [[ $waited -ge $RESTART_TIMEOUT ]]; then
            echo "Error: Tomcat7 did not restart within ${RESTART_TIMEOUT}s" >&2
            return 1
        fi
    done
}

housekeeping() {
    # Throttle: only run once per hour (3600 seconds)
    local now
    now=$(date +%s)
    if [[ $((now - _LAST_HOUSEKEEPING)) -lt 3600 ]]; then
        return
    fi
    _LAST_HOUSEKEEPING=$now

    # Compress incident directories older than 1 hour
    find "${OUTPUT_DIR}/incidents" -mindepth 1 -maxdepth 1 -type d \
        -mmin +60 \
        -exec sh -c '
            for dir; do
                base=$(basename "$dir")
                parent=$(dirname "$dir")
                tar czf "${parent}/${base}.tar.gz" -C "$parent" "$base" 2>/dev/null && rm -rf "$dir"
            done
        ' _ {} + 2>/dev/null || true

    # Purge old compressed incidents
    find "${OUTPUT_DIR}/incidents" -name "*.tar.gz" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

    # Purge old snapshot date directories
    find "${OUTPUT_DIR}/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
}

main() {
    load_config
    setup_mysql_cnf
    mkdir -p "$OUTPUT_DIR" "${OUTPUT_DIR}/incidents"

    echo "isanteplus-monitor started"
    echo "  URL:            $SESSION_URL"
    echo "  Timeout:        ${TIMEOUT}s"
    echo "  Poll interval:  ${POLL_INTERVAL}s"
    echo "  Restart Tomcat: $RESTART_TOMCAT"
    echo "  Heap dumps:     $ENABLE_HEAP_DUMP"
    echo "  Output dir:     $OUTPUT_DIR"
    echo "  Retention:      ${RETENTION_DAYS} days"

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time "$TIMEOUT" "$SESSION_URL" 2>/dev/null) || true

        # Trigger on: timeout/connection failure (000), empty, or server errors (5xx)
        # Note: 401/403 are considered "healthy" — OpenMRS is running and responding.
        # The -ge comparison is guarded by the earlier checks for non-numeric values.
        if [[ "$http_code" == "000" || -z "$http_code" ]] || [[ "$http_code" =~ ^[0-9]+$ && "$http_code" -ge 500 ]]; then
            echo "$(date): $SESSION_URL unhealthy (HTTP $http_code)"

            local old_pid
            old_pid=$(find_tomcat_pid)

            collect_diagnostics

            if [[ "$RESTART_TOMCAT" == "true" ]]; then
                restart_tomcat
                wait_for_new_pid "$old_pid" || true
            fi

            echo "$(date): Resuming monitoring"
        fi

        housekeeping

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
