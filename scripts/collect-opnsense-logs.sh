#!/usr/bin/env bash
# collect-opnsense-logs.sh — Pull logs and configs from OPNsense via SSH
# Maps to: docs/opnsense-guide.md Sections 7.6, 8.6
#
# Usage:
#   ./scripts/collect-opnsense-logs.sh [OPNSENSE_IP] [SSH_USER]
#
# Examples:
#   ./scripts/collect-opnsense-logs.sh                    # root@10.0.0.1 (LAN)
#   ./scripts/collect-opnsense-logs.sh 192.168.1.50       # WAN IP if LAN is down
#   ./scripts/collect-opnsense-logs.sh 10.0.0.1 admin     # custom SSH user

set -euo pipefail

OPNSENSE_IP="${1:-${OPNSENSE_LAN:-10.0.0.1}}"
SSH_USER="${2:-root}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="logs/opnsense-${TIMESTAMP}"
SSH_CMD="ssh ${SSH_USER}@${OPNSENSE_IP}"

print_usage() {
    cat <<'USAGE'
Usage: collect-opnsense-logs.sh [OPNSENSE_IP] [SSH_USER]

Collects Kea DHCP logs, Unbound DNS logs, configs, lease database,
and service status from OPNsense via SSH for offline analysis.

Arguments:
  OPNSENSE_IP   OPNsense IP address (default: $OPNSENSE_LAN or 10.0.0.1)
  SSH_USER      SSH username (default: root)

Environment:
  OPNSENSE_LAN  Override default OPNsense IP

Prerequisites:
  - SSH key copied to OPNsense (ssh-copy-id root@10.0.0.1)
  - Or be ready to enter password for each command

Output:
  logs/opnsense-<timestamp>/  directory with all collected data
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_usage
    exit 0
fi

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# Test SSH connectivity
log_info "Testing SSH connection to ${SSH_USER}@${OPNSENSE_IP}..."
if ! ${SSH_CMD} "echo ok" >/dev/null 2>&1; then
    log_error "Cannot SSH to ${SSH_USER}@${OPNSENSE_IP}"
    log_error "Ensure SSH is enabled on OPNsense and your key is copied:"
    log_error "  ssh-copy-id ${SSH_USER}@${OPNSENSE_IP}"
    exit 1
fi

mkdir -p "${OUTDIR}"
log_info "Collecting logs to ${OUTDIR}/"

# Collect remote command outputs
collect_cmd() {
    local desc="$1"
    local filename="$2"
    local cmd="$3"
    log_info "  ${desc}..."
    if ${SSH_CMD} "${cmd}" > "${OUTDIR}/${filename}" 2>&1; then
        local lines
        lines=$(wc -l < "${OUTDIR}/${filename}")
        log_info "    -> ${filename} (${lines} lines)"
    else
        log_warn "    -> ${filename} (command failed, see file for error)"
    fi
}

# Collect remote files via scp
collect_file() {
    local desc="$1"
    local remote_path="$2"
    local local_name="$3"
    log_info "  ${desc}..."
    if scp -q "${SSH_USER}@${OPNSENSE_IP}:${remote_path}" "${OUTDIR}/${local_name}" 2>/dev/null; then
        local lines
        lines=$(wc -l < "${OUTDIR}/${local_name}")
        log_info "    -> ${local_name} (${lines} lines)"
    else
        log_warn "    -> ${local_name} (file not found or access denied)"
    fi
}

echo ""
log_info "=== Service Status ==="
collect_cmd "Kea DHCP status"      "kea-status.txt"      "configctl kea status 2>&1 || echo 'Kea status command failed'"
collect_cmd "Unbound DNS status"   "unbound-status.txt"   "service unbound status 2>&1 || echo 'not running'"
collect_cmd "Port 53 listeners"    "port53.txt"           "sockstat -4 -l | grep :53 || echo 'nothing on port 53'"
collect_cmd "Port 67 listeners"    "port67.txt"           "sockstat -4 -l | grep :67 || echo 'nothing on port 67'"

echo ""
log_info "=== Logs (OPNsense 25 — syslog-ng flat files) ==="
collect_cmd "Kea DHCP logs"        "kea.log"              "grep -ri kea /var/log/system/latest.log /var/log/messages 2>/dev/null | tail -10000 || echo 'no kea logs found'"
collect_cmd "Unbound DNS logs"     "unbound.log"          "grep -ri unbound /var/log/system/latest.log /var/log/messages 2>/dev/null | tail -10000 || echo 'no unbound logs found'"
collect_cmd "Full system log"      "system.log"           "cat /var/log/system/latest.log 2>/dev/null || cat /var/log/messages 2>/dev/null || echo 'no system log found'"

echo ""
log_info "=== Configuration Files ==="
collect_file "Kea DHCP config"     "/usr/local/etc/kea/kea-dhcp4.conf"   "kea-dhcp4.conf"
collect_file "Unbound config"      "/var/unbound/unbound.conf"            "unbound.conf"

echo ""
log_info "=== Lease Database ==="
collect_file "Kea lease database"  "/var/db/kea/kea-leases4.csv"        "kea-leases4.csv"

echo ""
log_info "=== Network State ==="
collect_cmd "Interface config"     "ifconfig.txt"         "ifconfig"
collect_cmd "ARP table"            "arp.txt"              "arp -a"
collect_cmd "Routing table"        "routes.txt"           "netstat -rn"

echo ""
log_info "=== Quick Analysis ==="

# Check for declined leases
if [ -f "${OUTDIR}/kea-leases4.csv" ]; then
    declined=$(awk -F, '$10 == "1"' "${OUTDIR}/kea-leases4.csv" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$declined" -gt 0 ]; then
        log_warn "Found ${declined} declined lease(s) in Kea database (state=1):"
        awk -F, '$10 == "1"' "${OUTDIR}/kea-leases4.csv" | head -5
        echo "  (See docs/opnsense-guide.md Section 7.6 step 9 for fix)"
    else
        log_info "No declined leases found in Kea database"
    fi
fi

# Check for Kea allocation failures
if [ -f "${OUTDIR}/kea.log" ]; then
    alloc_fails=$(grep -c "ALLOC_ENGINE_V4_ALLOC_FAIL_SUBNET" "${OUTDIR}/kea.log" 2>/dev/null || echo "0")
    if [ "$alloc_fails" -gt 0 ]; then
        log_warn "Found ${alloc_fails} DHCP allocation failure(s) in Kea logs"
        log_warn "Recent failures:"
        grep "ALLOC_ENGINE_V4_DISCOVER_ADDRESS_CONFLICT" "${OUTDIR}/kea.log" | tail -3
    fi
fi

# Check Unbound status (cross-reference service status with sockstat)
if [ -f "${OUTDIR}/unbound-status.txt" ] && [ -f "${OUTDIR}/port53.txt" ]; then
    service_says_down=$(grep -q "not running" "${OUTDIR}/unbound-status.txt" && echo "yes" || echo "no")
    sockstat_says_up=$(grep -q "unbound" "${OUTDIR}/port53.txt" && echo "yes" || echo "no")
    if [ "$service_says_down" = "yes" ] && [ "$sockstat_says_up" = "yes" ]; then
        log_warn "Unbound PID mismatch: 'service unbound status' says not running but unbound IS listening on port 53"
        log_warn "This is a PID file issue, not an actual outage — see docs/opnsense-guide.md Section 8.6"
    elif [ "$service_says_down" = "yes" ]; then
        log_warn "Unbound DNS is NOT running — see docs/opnsense-guide.md Section 8.6"
    else
        log_info "Unbound DNS appears to be running"
    fi
fi

# Check for uppercase MAC in Kea reservations
if [ -f "${OUTDIR}/kea-dhcp4.conf" ]; then
    if grep -q '"hw-address":.*[A-F]' "${OUTDIR}/kea-dhcp4.conf"; then
        log_warn "Kea config contains UPPERCASE MAC addresses in reservations"
        grep '"hw-address"' "${OUTDIR}/kea-dhcp4.conf"
        echo "  (See docs/opnsense-guide.md Section 7.6 step 3 — should be lowercase)"
    fi
fi

echo ""
log_info "Collection complete: ${OUTDIR}/"
log_info "Files collected:"
ls -1 "${OUTDIR}/"
