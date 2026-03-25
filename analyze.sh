#!/usr/bin/env bash
# analyze.sh — Post-crash forensic analysis
# Finds snapshots around an incident and prints a summary.
#
# Usage:
#   ./analyze.sh                     # latest incident
#   ./analyze.sh --list              # list all incidents
#   ./analyze.sh --csv YYYYMMDD      # dump metrics CSV for a date
#   ./analyze.sh 2026-03-25T14:30:00 # analyze specific incident

set -euo pipefail

CONFIG_FILE="${ISANTEPLUS_MONITOR_CONFIG:-/etc/isanteplus-monitor.conf}"

OUTPUT_DIR="/var/log/isanteplus-monitor"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

INCIDENT_DIR="${OUTPUT_DIR}/incidents"
SNAP_DIR="${OUTPUT_DIR}/snapshots"

# ── Colors ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m' YELLOW='\033[0;33m' GREEN='\033[0;32m'
    CYAN='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

list_incidents() {
    echo -e "${BOLD}=== Incidents ===${RESET}"
    if [[ ! -d "$INCIDENT_DIR" ]]; then
        echo "No incidents directory found."
        return
    fi
    # List both directories and tar.gz (compressed old incidents)
    find "$INCIDENT_DIR" -mindepth 1 -maxdepth 1 \( -type d -o -name '*.tar.gz' \) 2>/dev/null | sort -r | head -20
    echo ""
    local count
    count=$(find "$INCIDENT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    echo "Total: ${count} incident(s)"
}

dump_csv() {
    local date="$1"
    local csv="${SNAP_DIR}/${date}/metrics.csv"
    if [[ -f "$csv" ]]; then
        if command -v column &>/dev/null; then
            column -t -s',' "$csv"
        else
            cat "$csv"
        fi
    else
        echo "No metrics CSV for date: ${date}"
        echo "Available dates:"
        find "${SNAP_DIR}" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort | while read -r d; do basename "$d"; done
    fi
}

analyze_incident() {
    local incident_path="$1"

    if [[ ! -d "$incident_path" ]]; then
        # Maybe it's compressed
        if [[ -f "${incident_path}.tar.gz" ]]; then
            echo -e "${YELLOW}Incident is compressed. Extracting temporarily...${RESET}"
            local tmp
            tmp=$(mktemp -d)
            tar xzf "${incident_path}.tar.gz" -C "$tmp" 2>/dev/null
            incident_path="${tmp}/$(basename "$incident_path")"
            trap "rm -rf $tmp" EXIT
        else
            echo -e "${RED}Incident not found: $incident_path${RESET}"
            return 1
        fi
    fi

    local incident_name
    incident_name=$(basename "$incident_path")

    echo -e "${BOLD}${RED}=== INCIDENT: ${incident_name} ===${RESET}"
    echo ""

    # ── Thread dump summary ──────────────────────────────────────────
    if [[ -f "${incident_path}/threads.txt" ]]; then
        echo -e "${BOLD}--- Thread States ---${RESET}"
        grep 'java.lang.Thread.State:' "${incident_path}/threads.txt" 2>/dev/null | \
            sort | uniq -c | sort -rn || echo "  (no thread states found)"
        echo ""

        if grep -q 'Found.*deadlock' "${incident_path}/threads.txt" 2>/dev/null; then
            echo -e "${RED}${BOLD}DEADLOCK DETECTED!${RESET}"
            grep -A 20 'Found.*deadlock' "${incident_path}/threads.txt" 2>/dev/null | head -25
            echo ""
        fi

        local blocked
        blocked=$(grep -c 'BLOCKED' "${incident_path}/threads.txt" 2>/dev/null || echo "0")
        if [[ "$blocked" -gt 0 ]]; then
            echo -e "${YELLOW}${blocked} BLOCKED threads${RESET}"
        fi
    fi

    # ── GC stats ─────────────────────────────────────────────────────
    if [[ -f "${incident_path}/gc_stats.txt" ]]; then
        echo -e "${BOLD}--- GC Stats ---${RESET}"
        cat "${incident_path}/gc_stats.txt"
        echo ""
    fi

    # ── Heap histogram ───────────────────────────────────────────────
    if [[ -f "${incident_path}/heap_histo.txt" ]]; then
        echo -e "${BOLD}--- Top Heap Consumers ---${RESET}"
        head -15 "${incident_path}/heap_histo.txt"
        echo ""
    fi

    # ── MySQL ────────────────────────────────────────────────────────
    if [[ -f "${incident_path}/processlist.txt" ]]; then
        echo -e "${BOLD}--- MySQL Process List ---${RESET}"
        local active
        active=$(grep -c 'Command: Query' "${incident_path}/processlist.txt" 2>/dev/null || echo "0")
        echo "Active queries: ${active}"
        if [[ "$active" -gt 0 ]]; then
            grep -B1 -A5 'Command: Query' "${incident_path}/processlist.txt" 2>/dev/null | head -30
        fi
        echo ""
    fi

    if [[ -f "${incident_path}/innodb_status.txt" ]]; then
        if grep -q 'LOCK WAIT' "${incident_path}/innodb_status.txt" 2>/dev/null; then
            echo -e "${YELLOW}Lock waits detected in InnoDB${RESET}"
        fi
        if grep -q 'LATEST DETECTED DEADLOCK' "${incident_path}/innodb_status.txt" 2>/dev/null; then
            echo -e "${RED}Deadlock recorded in InnoDB${RESET}"
        fi
        echo ""
    fi

    # ── Memory ───────────────────────────────────────────────────────
    if [[ -f "${incident_path}/memory.txt" ]]; then
        echo -e "${BOLD}--- Memory ---${RESET}"
        cat "${incident_path}/memory.txt"
        echo ""
    fi

    # ── Metrics CSV window ───────────────────────────────────────────
    # Try to find the metrics CSV for the incident date
    local incident_date
    incident_date=$(echo "$incident_name" | sed 's/T.*//' | tr -d '-')
    local csv="${SNAP_DIR}/${incident_date}/metrics.csv"
    if [[ -f "$csv" ]]; then
        local incident_hhmmss
        incident_hhmmss=$(echo "$incident_name" | sed 's/.*T//' | tr -d ':' | cut -c1-6)
        echo -e "${BOLD}--- Metrics Around Incident (from continuous snapshots) ---${RESET}"
        echo -e "${CYAN}$(head -1 "$csv")${RESET}"
        # Show rows within ~5 min window
        local t_num t_before t_after
        t_num=$((10#${incident_hhmmss}))
        t_before=$(printf "%06d" $((t_num - 500)))
        t_after=$(printf "%06d" $((t_num + 500)))
        tail -n +2 "$csv" | while IFS=',' read -r ts rest; do
            row_time=$(echo "$ts" | cut -d'_' -f2)
            if [[ -n "$row_time" ]] && [[ "$row_time" -ge "$t_before" ]] && [[ "$row_time" -le "$t_after" ]] 2>/dev/null; then
                if [[ "$row_time" -ge "$incident_hhmmss" ]] && [[ "$row_time" -le $((t_num + 100)) ]] 2>/dev/null; then
                    echo -e "${RED}>>> ${ts},${rest}${RESET}"
                else
                    echo "    ${ts},${rest}"
                fi
            fi
        done
        echo ""
    fi

    echo -e "${BOLD}=== END ===${RESET}"
}

# ── Main ─────────────────────────────────────────────────────────────
case "${1:-}" in
    --list)
        list_incidents
        ;;
    --csv)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 --csv YYYYMMDD"
            exit 1
        fi
        dump_csv "$2"
        ;;
    --help|-h)
        echo "iSantePlus Monitor — Post-Crash Analysis"
        echo ""
        echo "Usage:"
        echo "  $0                           Analyze latest incident"
        echo "  $0 --list                    List all incidents"
        echo "  $0 --csv YYYYMMDD            Dump metrics CSV for date"
        echo "  $0 2026-03-25T14:30:00       Analyze specific incident"
        echo "  $0 --help                    Show this help"
        ;;
    "")
        # Latest incident
        latest=$(find "$INCIDENT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -1 || true)
        if [[ -z "$latest" ]]; then
            echo "No incidents found in: $INCIDENT_DIR"
            exit 0
        fi
        analyze_incident "$latest"
        ;;
    *)
        analyze_incident "${INCIDENT_DIR}/${1}"
        ;;
esac
