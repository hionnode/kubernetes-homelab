#!/bin/bash
set -euo pipefail

# Homelab Diagnostic: Pre-Update Safety Checks
# Maps to: docs/opnsense-guide.md Section 13.4
# Runs from: Workstation (SSH access to Proxmox and OPNsense)

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-192.168.1.110}"
OPNSENSE_LAN="${OPNSENSE_LAN:-10.0.0.1}"
OPNSENSE_VMID="${OPNSENSE_VMID:-101}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

# SSH options
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Pre-update safety checks for OPNsense firmware updates."
    echo "Creates a Proxmox snapshot and records current system state."
    echo ""
    echo "Options:"
    echo "  --backup-config   Also download OPNsense config.xml via SCP"
    echo "  -h, --help        Show this help message"
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
    echo "See: docs/opnsense-guide.md Section 13.4"
}

BACKUP_CONFIG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --backup-config)
            BACKUP_CONFIG=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

DATE_STAMP=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="pre-update-$DATE_STAMP"
STATE_FILE="$OUTPUT_DIR/pre-update-state-$TIMESTAMP.txt"

echo ""
log_info "=== Pre-Update Safety Checks ==="
log_info "Proxmox: $PROXMOX_HOST | OPNsense: $OPNSENSE_LAN | VM: $OPNSENSE_VMID"
echo ""

# ── Step 1: Pre-flight SSH checks ───────────────────────────────────────────────

log_info "── Step 1: Pre-flight SSH checks ──"

# Test Proxmox SSH
# shellcheck disable=SC2086
if ssh $SSH_OPTS "root@$PROXMOX_HOST" "echo ok" >/dev/null 2>&1; then
    log_pass "SSH to Proxmox ($PROXMOX_HOST) works"
else
    log_fail "SSH to Proxmox ($PROXMOX_HOST) failed"
    log_error "Ensure SSH key-based access is configured: ssh-copy-id root@$PROXMOX_HOST"
    exit 1
fi

# Test OPNsense SSH
# shellcheck disable=SC2086
if ssh $SSH_OPTS "root@$OPNSENSE_LAN" "echo ok" >/dev/null 2>&1; then
    log_pass "SSH to OPNsense ($OPNSENSE_LAN) works"
else
    log_fail "SSH to OPNsense ($OPNSENSE_LAN) failed"
    log_error "Ensure SSH is enabled (console option 14) and key-based access is configured."
    exit 1
fi

echo ""

# ── Step 2: Create Proxmox snapshot ─────────────────────────────────────────────

log_info "── Step 2: Create Proxmox snapshot ──"

# Check for existing same-day snapshot
# shellcheck disable=SC2086,SC2029
EXISTING=$(ssh $SSH_OPTS "root@$PROXMOX_HOST" "qm listsnapshot $OPNSENSE_VMID" 2>/dev/null || true)
if echo "$EXISTING" | grep -q "$SNAPSHOT_NAME"; then
    log_warn "Snapshot '$SNAPSHOT_NAME' already exists for today"
    log_warn "Skipping snapshot creation. Delete it first if you need a fresh one:"
    echo "  ssh root@$PROXMOX_HOST \"qm delsnapshot $OPNSENSE_VMID --snapname $SNAPSHOT_NAME\""
else
    log_info "Creating snapshot '$SNAPSHOT_NAME' for VM $OPNSENSE_VMID..."
    # shellcheck disable=SC2086,SC2029
    if ssh $SSH_OPTS "root@$PROXMOX_HOST" "qm snapshot $OPNSENSE_VMID --snapname $SNAPSHOT_NAME --description 'Before OPNsense update $(date +%Y-%m-%d)'"; then
        log_pass "Snapshot '$SNAPSHOT_NAME' created"
    else
        log_fail "Failed to create snapshot"
        log_error "Check Proxmox storage space and VM state."
        exit 1
    fi
fi

echo ""

# ── Step 3: Record current state ────────────────────────────────────────────────

log_info "── Step 3: Record current OPNsense state ──"
log_info "Saving to: $STATE_FILE"

{
    echo "OPNsense Pre-Update State"
    echo "Generated: $(date)"
    echo "Snapshot: $SNAPSHOT_NAME"
    echo ""
} > "$STATE_FILE"

# Collect state from OPNsense (individual failures are diagnostic data)
record_state() {
    local label="$1"
    local cmd="$2"
    echo "--- $label ---" >> "$STATE_FILE"
    # shellcheck disable=SC2086,SC2029
    (set +e; ssh $SSH_OPTS "root@$OPNSENSE_LAN" "$cmd" >> "$STATE_FILE" 2>&1; true)
    echo "" >> "$STATE_FILE"
}

record_state "OPNsense version" "opnsense-version"
record_state "Interfaces" "ifconfig -a"
record_state "Firewall rule count" "pfctl -s rules | wc -l"
record_state "Firewall rules" "pfctl -s rules"
record_state "NAT rules" "pfctl -s nat"
record_state "DHCP status" "pluginctl -s dhcpd"
record_state "DNS status" "service unbound status"
record_state "Enabled services" "service -e"
record_state "Installed packages" "pkg info"
record_state "Routing table" "netstat -rn"
record_state "Listening ports" "sockstat -4 -l"

log_pass "State recorded to $STATE_FILE"
echo ""

# ── Step 4 (Optional): Backup config.xml ────────────────────────────────────────

if $BACKUP_CONFIG; then
    log_info "── Step 4: Backup config.xml ──"

    CONFIG_FILE="$OUTPUT_DIR/config-backup-$TIMESTAMP.xml"

    # shellcheck disable=SC2086
    if scp $SSH_OPTS "root@$OPNSENSE_LAN:/conf/config.xml" "$CONFIG_FILE" 2>/dev/null; then
        # Sanity check file size (should be >10KB for a configured system)
        FILE_SIZE=$(wc -c < "$CONFIG_FILE" | tr -d ' ')
        if [[ "$FILE_SIZE" -gt 10240 ]]; then
            log_pass "Config backup saved to $CONFIG_FILE ($FILE_SIZE bytes)"
        else
            log_warn "Config backup is suspiciously small ($FILE_SIZE bytes) — may be incomplete"
        fi
    else
        log_fail "Failed to download config.xml via SCP"
        log_error "Check SSH access and that /conf/config.xml exists on OPNsense."
    fi
    echo ""
fi

# ── Summary ─────────────────────────────────────────────────────────────────────

log_info "=== Pre-Update Summary ==="
echo ""
echo "  Snapshot:    $SNAPSHOT_NAME (on Proxmox VM $OPNSENSE_VMID)"
echo "  State file:  $STATE_FILE"
if $BACKUP_CONFIG; then
    echo "  Config:      ${CONFIG_FILE:-not saved}"
fi
echo ""
log_info "Rollback command (if update goes wrong):"
echo ""
echo "  ssh root@$PROXMOX_HOST \"qm stop $OPNSENSE_VMID && qm rollback $OPNSENSE_VMID --snapname $SNAPSHOT_NAME && qm start $OPNSENSE_VMID\""
echo ""
log_info "You are safe to proceed with the OPNsense update."
log_info "See: troubleshooting guide Section 13 for post-update recovery."
