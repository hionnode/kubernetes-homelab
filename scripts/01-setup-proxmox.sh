#!/bin/bash
set -euo pipefail

# Homelab Setup Script 1: Proxmox Initial Configuration
# This script sets up Proxmox networking and creates the OPNsense VM

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-192.168.1.110}"
WAN_INTERFACE="${WAN_INTERFACE:-enp2s0}"
LAN_INTERFACE="${LAN_INTERFACE:-enx1c860b363f63}"
OPNSENSE_VMID="${OPNSENSE_VMID:-100}"
OPNSENSE_ISO_URL="${OPNSENSE_ISO_URL:-https://pkg.opnsense.org/releases/25.7/OPNsense-25.7-dvd-amd64.iso.bz2}"

log_info "Starting Proxmox setup for homelab..."

# Check if running on Proxmox or remote
if [ -f /etc/pve/.version ]; then
    log_info "Running on Proxmox host directly"
    SSH_CMD=""
else
    log_info "Running remotely, will SSH to $PROXMOX_HOST"
    SSH_CMD="ssh root@$PROXMOX_HOST"
fi

# Function to execute commands (local or remote)
run_cmd() {
    if [ -z "$SSH_CMD" ]; then
        bash -c "$1"
    else
        $SSH_CMD "$1"
    fi
}

# Step 1: Backup network configuration
log_info "Backing up /etc/network/interfaces..."
run_cmd "cp /etc/network/interfaces /etc/network/interfaces.backup.\$(date +%Y%m%d-%H%M%S)"

# Step 2: Configure vmbr1 if not exists
log_info "Checking for vmbr1..."
if run_cmd "ip link show vmbr1 2>/dev/null" >/dev/null 2>&1; then
    log_warn "vmbr1 already exists, skipping creation"
else
    log_info "Creating vmbr1 for LAN network..."
    run_cmd "cat >> /etc/network/interfaces << 'EOF'

iface $LAN_INTERFACE inet manual

auto vmbr1
iface vmbr1 inet manual
        bridge-ports $LAN_INTERFACE
        bridge-stp off
        bridge-fd 0
        comment LAN Bridge for OPNsense
EOF
"
    
    log_info "Bringing up interfaces..."
    run_cmd "ip link set $LAN_INTERFACE up && ifreload -a"
    log_info "vmbr1 created successfully"
fi

# Step 3: Download OPNsense ISO
log_info "Checking for OPNsense ISO..."
ISO_NAME="opnsense-25.7.iso"
ISO_PATH="/var/lib/vz/template/iso/$ISO_NAME"

if run_cmd "test -f $ISO_PATH"; then
    log_warn "OPNsense ISO already exists, skipping download"
else
    log_info "Downloading and decompressing OPNsense ISO..."
    run_cmd "cd /var/lib/vz/template/iso && wget -O - $OPNSENSE_ISO_URL | bunzip2 > $ISO_NAME"
    log_info "ISO downloaded successfully"
fi

# Step 4: Create OPNsense VM if not exists
log_info "Checking for OPNsense VM..."
if run_cmd "qm status $OPNSENSE_VMID 2>/dev/null" >/dev/null 2>&1; then
    log_warn "VM $OPNSENSE_VMID already exists, skipping creation"
else
    log_info "Creating OPNsense VM ($OPNSENSE_VMID)..."
    run_cmd "qm create $OPNSENSE_VMID \\
        --name opnsense \\
        --cores 2 \\
        --memory 2048 \\
        --net0 virtio,bridge=vmbr0 \\
        --net1 virtio,bridge=vmbr1 \\
        --scsi0 local-lvm:16 \\
        --ide2 local:iso/$ISO_NAME,media=cdrom \\
        --boot order=ide2 \\
        --ostype l26 \\
        --agent 1"
    
    log_info "Starting VM for initial install..."
    run_cmd "qm start $OPNSENSE_VMID"
    log_info "OPNsense VM created and started"
fi

log_info "Proxmox setup complete!"
echo ""
log_info "Next steps:"
echo "  1. Access OPNsense console: Proxmox GUI → VM $OPNSENSE_VMID → Console"
echo "  2. Login with: installer / opnsense"
echo "  3. Run: opnsense-installer"
echo "  4. After installation, configure interfaces:"
echo "     - vtnet0 → WAN (DHCP)"
echo "     - vtnet1 → LAN (10.0.0.1/24)"
echo "  5. Generate API keys in OPNsense GUI"
echo "  6. Run: ./02-setup-opnsense.sh"
