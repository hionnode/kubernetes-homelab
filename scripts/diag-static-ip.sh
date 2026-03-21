#!/bin/bash
set -euo pipefail

# Homelab Diagnostic: Emergency Static IP Assignment
# Maps to: docs/opnsense-troubleshooting-guide.md Section 4.2
# Runs from: Workstation (requires sudo)

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
STATIC_IP="${STATIC_IP:-10.0.0.199}"
SUBNET_MASK="${SUBNET_MASK:-255.255.255.0}"
CIDR="${CIDR:-24}"
GATEWAY="${GATEWAY:-10.0.0.1}"

# Platform detection
OS=$(uname -s)

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Emergency static IP assignment for when DHCP is down."
    echo "Assigns $STATIC_IP/$CIDR with gateway $GATEWAY to your LAN interface."
    echo ""
    echo "Modes:"
    echo "  (default)     Assign static IP"
    echo "  --cleanup     Remove static IP and restore DHCP"
    echo ""
    echo "Options:"
    echo "  --interface <name>   Specify network interface (auto-detected if omitted)"
    echo "  --yes                Skip confirmation prompt"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  STATIC_IP     IP to assign (default: 10.0.0.199)"
    echo "  GATEWAY       Gateway IP (default: 10.0.0.1)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                        # Auto-detect interface, assign IP"
    echo "  $(basename "$0") --interface en7         # Use specific interface"
    echo "  $(basename "$0") --cleanup               # Remove static IP, restore DHCP"
    echo ""
    echo "See: docs/opnsense-troubleshooting-guide.md Section 4.2"
}

# Parse arguments
MODE="assign"
INTERFACE=""
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --cleanup)
            MODE="cleanup"
            shift
            ;;
        --interface)
            INTERFACE="$2"
            shift 2
            ;;
        --yes)
            SKIP_CONFIRM=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ── Interface detection ─────────────────────────────────────────────────────────

detect_interface_linux() {
    # Find a non-loopback, UP, ethernet interface
    local iface
    iface=$(ip -o link show | grep -v "lo:" | grep "state UP" | grep -v "wlan\|wl" | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    if [[ -z "$iface" ]]; then
        # Fallback: any non-loopback interface that is UP
        iface=$(ip -o link show | grep -v "lo:" | grep "state UP" | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    fi
    echo "$iface"
}

detect_interface_macos() {
    # Look for Ethernet or USB LAN adapter
    local service
    service=$(networksetup -listallhardwareports | grep -A1 -i "ethernet\|USB" | grep "Device:" | head -1 | awk '{print $2}')
    if [[ -z "$service" ]]; then
        # Fallback to en0
        service="en0"
    fi
    echo "$service"
}

get_macos_service_name() {
    local device="$1"
    # Map BSD device name to networksetup service name
    networksetup -listallhardwareports | grep -B1 "Device: $device" | head -1 | sed 's/Hardware Port: //'
}

if [[ -z "$INTERFACE" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
        INTERFACE=$(detect_interface_macos)
    else
        INTERFACE=$(detect_interface_linux)
    fi

    if [[ -z "$INTERFACE" ]]; then
        log_error "Could not auto-detect a network interface."
        log_error "Specify one with: $(basename "$0") --interface <name>"
        echo ""
        if [[ "$OS" == "Darwin" ]]; then
            echo "Available interfaces:"
            networksetup -listallhardwareports
        else
            echo "Available interfaces:"
            ip -o link show | grep -v "lo:"
        fi
        exit 1
    fi
fi

# ── Cleanup mode ────────────────────────────────────────────────────────────────

if [[ "$MODE" == "cleanup" ]]; then
    log_info "=== Cleanup: Removing Static IP ==="
    log_info "Interface: $INTERFACE"
    echo ""

    if [[ "$OS" == "Darwin" ]]; then
        SERVICE_NAME=$(get_macos_service_name "$INTERFACE")
        if [[ -z "$SERVICE_NAME" ]]; then
            log_error "Could not find networksetup service name for $INTERFACE"
            exit 1
        fi
        log_info "Restoring DHCP on '$SERVICE_NAME' ($INTERFACE)..."
        sudo networksetup -setdhcp "$SERVICE_NAME"
        log_pass "DHCP restored on $SERVICE_NAME"
    else
        log_info "Removing $STATIC_IP/$CIDR from $INTERFACE..."
        if sudo ip addr del "$STATIC_IP/$CIDR" dev "$INTERFACE" 2>/dev/null; then
            log_pass "Static IP removed"
        else
            log_warn "Static IP was not assigned (already clean)"
        fi

        log_info "Restarting network service..."
        if command -v nmcli >/dev/null 2>&1; then
            sudo systemctl restart NetworkManager
            log_pass "NetworkManager restarted"
        elif command -v dhclient >/dev/null 2>&1; then
            sudo dhclient "$INTERFACE"
            log_pass "DHCP lease requested via dhclient"
        else
            log_warn "No network manager found — you may need to manually request a DHCP lease"
        fi
    fi

    echo ""
    log_info "Cleanup complete. DHCP should assign a new address shortly."
    exit 0
fi

# ── Assign mode ─────────────────────────────────────────────────────────────────

echo ""
log_info "=== Emergency Static IP Assignment ==="
log_info "Interface: $INTERFACE"
log_info "IP:        $STATIC_IP/$CIDR"
log_info "Gateway:   $GATEWAY"
echo ""

# Confirmation
if ! $SKIP_CONFIRM; then
    log_warn "This will assign a static IP to $INTERFACE."
    log_warn "Remember to run '$(basename "$0") --cleanup' when done."
    echo ""
    read -rp "Continue? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
    echo ""
fi

if [[ "$OS" == "Darwin" ]]; then
    SERVICE_NAME=$(get_macos_service_name "$INTERFACE")
    if [[ -z "$SERVICE_NAME" ]]; then
        log_error "Could not find networksetup service name for $INTERFACE"
        exit 1
    fi
    log_info "Assigning static IP via networksetup on '$SERVICE_NAME'..."
    sudo networksetup -setmanual "$SERVICE_NAME" "$STATIC_IP" "$SUBNET_MASK" "$GATEWAY"
    log_pass "Static IP assigned to $SERVICE_NAME ($INTERFACE)"
else
    log_info "Assigning static IP via ip command..."
    sudo ip addr add "$STATIC_IP/$CIDR" dev "$INTERFACE"
    log_pass "Static IP $STATIC_IP/$CIDR assigned to $INTERFACE"

    log_info "Adding default route via $GATEWAY..."
    sudo ip route add default via "$GATEWAY" dev "$INTERFACE" 2>/dev/null || \
        log_warn "Default route already exists or could not be added"
fi

echo ""

# Verify connectivity
log_info "Verifying connectivity to gateway ($GATEWAY)..."

ping_once() {
    if [[ "$OS" == "Darwin" ]]; then
        ping -c 1 -t 3 "$1" >/dev/null 2>&1
    else
        ping -c 1 -W 3 "$1" >/dev/null 2>&1
    fi
}

if ping_once "$GATEWAY"; then
    log_pass "Gateway ($GATEWAY) is reachable"
else
    log_fail "Gateway ($GATEWAY) is not reachable"
    log_error "  Static IP was assigned but gateway is not responding."
    log_error "  Possible causes:"
    log_error "    - OPNsense VM is not running"
    log_error "    - Wrong interface selected (try --interface <name>)"
    log_error "    - Cable not connected to LAN switch"
fi

echo ""
log_warn "REMINDER: Run '$(basename "$0") --cleanup' after troubleshooting!"
log_warn "Leaving a static IP can cause conflicts when DHCP is restored."
echo ""
log_info "Next steps:"
echo "  - Access OPNsense WebGUI: https://$GATEWAY"
echo "  - SSH to OPNsense: ssh root@$GATEWAY"
echo "  - Run health check: scripts/diag-health-check.sh"
