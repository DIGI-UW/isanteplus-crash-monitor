#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${ISANTEPLUS_MONITOR_CONFIG:-/etc/isanteplus-monitor.conf}"

# Defaults (overridden by config file)
SESSION_URL="http://localhost:8080/openmrs/ws/rest/v1/session"
TIMEOUT=15
POLL_INTERVAL=15
OUTPUT_DIR="/var/log/isanteplus-monitor"
OPENMRS_LOG="/usr/share/tomcat7/.OpenMRS/openmrs.log"
RESTART_TOMCAT=true
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_DATABASE="openmrs"
MYSQL_HOST="localhost"

# Max time to wait for Tomcat to come back after a restart (in seconds)
RESTART_TIMEOUT=300

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
    # Look for the Tomcat7 JVM process
    pgrep -f 'catalina.startup.Bootstrap' | head -n 1 || true
}

# Write a temporary MySQL option file and pass it to mysql via
# --defaults-extra-file so the password never appears in the process table.
mysql_cmd() {
    local tmp_cnf
    tmp_cnf=$(mktemp /tmp/isanteplus-mysql.XXXXXX)
    chmod 600 "$tmp_cnf"

    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "host=${MYSQL_HOST}"
        if [[ -n "$MYSQL_PASSWORD" ]]; then
            echo "password=${MYSQL_PASSWORD}"
        fi
    } > "$tmp_cnf"

    # Ensure the temp file is cleaned up regardless of how mysql exits
    mysql --defaults-extra-file="$tmp_cnf" "$MYSQL_DATABASE" "$@"
    local rc=$?
    rm -f "$tmp_cnf"
    return $rc
}

collect_diagnostics() {
    local timestamp
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
    local incident_dir="${OUTPUT_DIR}/${timestamp}"

    mkdir -p "$incident_dir"
    echo "Collecting diagnostics in $incident_dir"

    # 1. Copy OpenMRS log
    if [[ -f "$OPENMRS_LOG" ]]; then
        cp "$OPENMRS_LOG" "${incident_dir}/openmrs.log"
        echo "  Copied openmrs.log"
    else
        echo "  Warning: $OPENMRS_LOG not found" >&2
    fi

    # 2. InnoDB status
    if mysql_cmd -e "SHOW ENGINE INNODB STATUS\G" > "${incident_dir}/innodb_status.txt" 2>&1; then
        echo "  Captured InnoDB status"
    else
        echo "  Warning: failed to capture InnoDB status" >&2
    fi

    # 3. Full process list
    if mysql_cmd -e "SHOW FULL PROCESSLIST\G" > "${incident_dir}/processlist.txt" 2>&1; then
        echo "  Captured MySQL process list"
    else
        echo "  Warning: failed to capture MySQL process list" >&2
    fi

    # 4. CPU and memory usage for all processes
    ps aux --sort=-%cpu > "${incident_dir}/ps_aux.txt" 2>&1 || true
    echo "  Captured process listing"

    # 5. Heap dump
    local tomcat_pid
    tomcat_pid=$(find_tomcat_pid)
    if [[ -n "$tomcat_pid" ]]; then
        if jmap -J-d64 -dump:format=b,file="${incident_dir}/heap.hprof" "$tomcat_pid" 2>&1; then
            echo "  Captured heap dump for PID $tomcat_pid"
        else
            echo "  Warning: jmap failed for PID $tomcat_pid" >&2
        fi
    else
        echo "  Warning: could not find Tomcat PID for heap dump" >&2
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

main() {
    load_config
    mkdir -p "$OUTPUT_DIR"

    echo "isanteplus-monitor started"
    echo "  URL:            $SESSION_URL"
    echo "  Timeout:        ${TIMEOUT}s"
    echo "  Poll interval:  ${POLL_INTERVAL}s"
    echo "  Restart Tomcat: $RESTART_TOMCAT"
    echo "  Output dir:     $OUTPUT_DIR"

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time "$TIMEOUT" "$SESSION_URL" 2>/dev/null) || true

        if [[ "$http_code" == "000" || -z "$http_code" ]]; then
            # Timeout or connection failure
            echo "$(date): Request to $SESSION_URL timed out or failed (code: $http_code)"

            local old_pid
            old_pid=$(find_tomcat_pid)

            collect_diagnostics

            if [[ "$RESTART_TOMCAT" == "true" ]]; then
                restart_tomcat
                wait_for_new_pid "$old_pid" || true
            fi

            echo "$(date): Resuming monitoring"
        fi

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
