#!/bin/bash
set -euo pipefail

# Homelab Diagnostic: Data Collector
# Maps to: docs/opnsense-troubleshooting-guide.md Section 3.3
# Runs from: Workstation (SSH access to Proxmox and OPNsense)

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-192.168.1.110}"
OPNSENSE_LAN="${OPNSENSE_LAN:-10.0.0.1}"
OPNSENSE_VMID="${OPNSENSE_VMID:-101}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

# SSH options: fail immediately if keys aren't set up
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# Platform detection
OS=$(uname -s)

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Collect diagnostic data from workstation, Proxmox, and OPNsense."
    echo "Saves everything to a timestamped file for analysis."
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  -o, --output <dir>   Output directory (default: current directory)"
    echo ""
    echo "Environment variables:"
    echo "  PROXMOX_HOST    Proxmox host IP (default: 192.168.1.110)"
    echo "  OPNSENSE_LAN    OPNsense LAN IP (default: 10.0.0.1)"
    echo "  OPNSENSE_VMID   OPNsense VM ID (default: 101)"
    echo "  OUTPUT_DIR       Output directory (default: .)"
    echo ""
    echo "Prerequisites:"
    echo "  - SSH key-based access to root@$PROXMOX_HOST"
    echo "  - SSH key-based access to root@$OPNSENSE_LAN"
    echo ""
    echo "See: docs/opnsense-troubleshooting-guide.md Section 3.3"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="$OUTPUT_DIR/diag-$TIMESTAMP.txt"

# Helper to run a command and capture output with header
section() {
    echo "" >> "$OUTPUT_FILE"
    echo "======================================================================" >> "$OUTPUT_FILE"
    echo "  $1" >> "$OUTPUT_FILE"
    echo "======================================================================" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
}

run_local() {
    local label="$1"
    local cmd="$2"
    echo "--- $label ---" >> "$OUTPUT_FILE"
    echo "\$ $cmd" >> "$OUTPUT_FILE"
    # Use set +e so command failures become diagnostic data
    (set +e; eval "$cmd" >> "$OUTPUT_FILE" 2>&1; true)
    echo "" >> "$OUTPUT_FILE"
}

run_ssh() {
    local host="$1"
    local label="$2"
    local cmd="$3"
    echo "--- $label ---" >> "$OUTPUT_FILE"
    echo "\$ ssh root@$host \"$cmd\"" >> "$OUTPUT_FILE"
    # shellcheck disable=SC2086
    (set +e; ssh $SSH_OPTS "root@$host" "$cmd" >> "$OUTPUT_FILE" 2>&1; true)
    echo "" >> "$OUTPUT_FILE"
}

ping_once() {
    local host="$1"
    if [[ "$OS" == "Darwin" ]]; then
        ping -c 1 -t 3 "$host" 2>&1
    else
        ping -c 1 -W 3 "$host" 2>&1
    fi
}

echo ""
log_info "=== Diagnostic Data Collection ==="
log_info "Output: $OUTPUT_FILE"
echo ""

# Initialize output file
{
    echo "Homelab Diagnostic Report"
    echo "Generated: $(date)"
    echo "Host: $(hostname)"
    echo ""
} > "$OUTPUT_FILE"

# ── Section 1: Workstation ──────────────────────────────────────────────────────

log_info "Collecting workstation data..."
section "WORKSTATION"

run_local "Date" "date"
run_local "Hostname" "hostname"
run_local "OS" "uname -a"

if [[ "$OS" == "Darwin" ]]; then
    run_local "Network interfaces" "ifconfig"
    run_local "Routing table" "netstat -rn"
else
    run_local "Network interfaces" "ip addr show"
    run_local "Routing table" "ip route show"
fi

# ── Section 2: Proxmox Host ────────────────────────────────────────────────────

log_info "Collecting Proxmox data (SSH to $PROXMOX_HOST)..."
section "PROXMOX HOST ($PROXMOX_HOST)"

# Test SSH first
# shellcheck disable=SC2086
if ssh $SSH_OPTS "root@$PROXMOX_HOST" "echo ok" >/dev/null 2>&1; then
    log_info "  SSH to Proxmox: connected"

    run_ssh "$PROXMOX_HOST" "VM $OPNSENSE_VMID status" "qm status $OPNSENSE_VMID"
    run_ssh "$PROXMOX_HOST" "VM $OPNSENSE_VMID config" "qm config $OPNSENSE_VMID"
    run_ssh "$PROXMOX_HOST" "Bridge vmbr0" "ip link show vmbr0"
    run_ssh "$PROXMOX_HOST" "Bridge vmbr1" "ip link show vmbr1"
    run_ssh "$PROXMOX_HOST" "Bridge members" "bridge link show"
    run_ssh "$PROXMOX_HOST" "VM events (last hour)" "journalctl -u pve-guests --since '1 hour ago' --no-pager 2>/dev/null || echo 'journalctl not available'"
else
    log_warn "  SSH to Proxmox failed — recording failure"
    echo "SSH to root@$PROXMOX_HOST FAILED" >> "$OUTPUT_FILE"
    echo "Ensure SSH key-based access is configured." >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
fi

# ── Section 3: OPNsense ────────────────────────────────────────────────────────

log_info "Collecting OPNsense data (SSH to $OPNSENSE_LAN)..."
section "OPNSENSE ($OPNSENSE_LAN)"

# Test SSH first
# shellcheck disable=SC2086
if ssh $SSH_OPTS "root@$OPNSENSE_LAN" "echo ok" >/dev/null 2>&1; then
    log_info "  SSH to OPNsense: connected"

    run_ssh "$OPNSENSE_LAN" "Version" "opnsense-version"
    run_ssh "$OPNSENSE_LAN" "Uptime" "uptime"
    run_ssh "$OPNSENSE_LAN" "Interfaces" "ifconfig -a"
    run_ssh "$OPNSENSE_LAN" "Routing table" "netstat -rn"
    run_ssh "$OPNSENSE_LAN" "Firewall state summary" "pfctl -s info"
    run_ssh "$OPNSENSE_LAN" "NAT rules" "pfctl -s nat"
    run_ssh "$OPNSENSE_LAN" "Firewall rules" "pfctl -s rules"
    run_ssh "$OPNSENSE_LAN" "DHCP service status" "pluginctl -s dhcpd"
    run_ssh "$OPNSENSE_LAN" "DNS service status" "service unbound status"
    run_ssh "$OPNSENSE_LAN" "Listening ports" "sockstat -4 -l"
    run_ssh "$OPNSENSE_LAN" "System log (last 50)" "clog /var/log/system.log | tail -50"
    run_ssh "$OPNSENSE_LAN" "Filter log (last 50)" "clog /var/log/filter.log | tail -50"
    run_ssh "$OPNSENSE_LAN" "DHCP leases" "cat /tmp/dhcpd.leases"
    run_ssh "$OPNSENSE_LAN" "Kernel messages (last 50)" "dmesg | tail -50"
else
    log_warn "  SSH to OPNsense failed — recording failure"
    echo "SSH to root@$OPNSENSE_LAN FAILED" >> "$OUTPUT_FILE"
    echo "Ensure SSH is enabled (OPNsense console option 14) and key-based access is configured." >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
fi

# ── Section 4: Connectivity Tests ───────────────────────────────────────────────

log_info "Running connectivity tests..."
section "CONNECTIVITY TESTS"

run_local "Ping Proxmox ($PROXMOX_HOST)" "ping_once $PROXMOX_HOST"
run_local "Ping OPNsense LAN ($OPNSENSE_LAN)" "ping_once $OPNSENSE_LAN"
run_local "Ping Internet (8.8.8.8)" "ping_once 8.8.8.8"

# K8s nodes
for IP in 10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.20 10.0.0.21 10.0.0.22; do
    run_local "Ping K8s node ($IP)" "ping_once $IP"
done

run_local "Ping K8s VIP (10.0.0.5)" "ping_once 10.0.0.5"

if command -v dig >/dev/null 2>&1; then
    run_local "DNS via OPNsense" "dig +short +time=3 @$OPNSENSE_LAN google.com"
    run_local "DNS via upstream" "dig +short +time=3 @1.1.1.1 google.com"
    run_local "DNS local override" "dig +short +time=3 @$OPNSENSE_LAN talos-cp-1.homelab.local"
fi

if command -v traceroute >/dev/null 2>&1; then
    run_local "Traceroute to 8.8.8.8" "traceroute -m 10 -w 2 8.8.8.8"
fi

if command -v nc >/dev/null 2>&1; then
    run_local "K8s API port (10.0.0.5:6443)" "nc -z -w 3 10.0.0.5 6443 && echo 'OPEN' || echo 'CLOSED'"
fi

# ── Done ────────────────────────────────────────────────────────────────────────

echo ""
log_info "=== Collection Complete ==="
log_info "Output saved to: $OUTPUT_FILE"

FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
log_info "File size: $FILE_SIZE bytes ($LINE_COUNT lines)"
echo ""
log_info "Review with: less $OUTPUT_FILE"
