#!/bin/bash
set -euo pipefail

# Homelab Setup Script 2: OPNsense Configuration
# This script configures OPNsense via API

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Configuration - READ FROM ENV OR PROMPT
OPNSENSE_HOST="${OPNSENSE_HOST:-}"
OPNSENSE_API_KEY="${OPNSENSE_API_KEY:-}"
OPNSENSE_API_SECRET="${OPNSENSE_API_SECRET:-}"

# Prompt for credentials if not set
if [ -z "$OPNSENSE_HOST" ]; then
    read -p "OPNsense WAN IP (e.g., 192.168.1.101): " OPNSENSE_HOST
fi

if [ -z "$OPNSENSE_API_KEY" ]; then
    read -p "OPNsense API Key: " OPNSENSE_API_KEY
fi

if [ -z "$OPNSENSE_API_SECRET" ]; then
    read -s -p "OPNsense API Secret: " OPNSENSE_API_SECRET
    echo ""
fi

API_URL="https://$OPNSENSE_HOST"
API_AUTH="$OPNSENSE_API_KEY:$OPNSENSE_API_SECRET"

log_info "Starting OPNsense configuration..."

# Helper function for API calls
opn_api() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    
    if [ -n "$data" ]; then
        curl -sk -X "$method" -u "$API_AUTH" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$API_URL$endpoint"
    else
        curl -sk -X "$method" -u "$API_AUTH" \
            "$API_URL$endpoint"
    fi
}

# Step 1: Configure NAT (Outbound)
log_info "Configuring NAT outbound rules..."
# OPNsense API for NAT is complex and varies by version
# This is a placeholder - actual implementation requires OPNsense API exploration
log_warn "NAT configuration via API not implemented - configure manually in GUI"

# Step 2: Configure Firewall Rules
log_info "Configuring firewall rules..."
# Allow LAN to any
RULE_JSON='{
  "action": "pass",
  "interface": "lan",
  "protocol": "any",
  "source_net": "any",
  "destination_net": "any",
  "description": "Allow LAN to Any"
}'
# Note: Actual OPNsense API endpoints may differ
log_warn "Firewall rules via API require specific OPNsense version - configure manually"

# Step 3: Apply Configuration
log_info "Applying configuration..."
# opn_api "POST" "/api/core/service/reconfigure" "{}"

log_info "OPNsense basic configuration attempt complete"
echo ""
log_warn "Note: Full API automation requires:"
echo "  - OPNsense API documentation specific to your version"
echo "  - Manual verification of API endpoints"
echo "  - Consider using opnsense-backup/restore for complex configs"
echo ""
log_info "Manually verify in GUI:"
echo "  1. Firewall → NAT → Outbound (should be auto)"
echo "  2. Firewall → Rules → LAN (allow all)"
echo "  3. Interfaces → Assignments (vtnet1 = LAN)"
