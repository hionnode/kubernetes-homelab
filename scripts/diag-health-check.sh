#!/bin/bash
set -euo pipefail

# Homelab Diagnostic: Five-Layer Health Check
# Maps to: docs/opnsense-guide.md Section 3.1
# Runs from: Workstation (no SSH required)

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

# Configuration (override via environment)
PROXMOX_HOST="${PROXMOX_HOST:-192.168.1.110}"
OPNSENSE_LAN="${OPNSENSE_LAN:-10.0.0.1}"
K8S_VIP="${K8S_VIP:-10.0.0.5}"
DNS_UPSTREAM="${DNS_UPSTREAM:-1.1.1.1}"

# Control plane and worker IPs
CP_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
WORKER_IPS=("10.0.0.20" "10.0.0.21" "10.0.0.22")

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Five-layer connectivity triage for the homelab network."
    echo "Works bottom-up: Proxmox → OPNsense → DNS → Internet → K8s nodes."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  PROXMOX_HOST   Proxmox host IP (default: 192.168.1.110)"
    echo "  OPNSENSE_LAN   OPNsense LAN IP (default: 10.0.0.1)"
    echo "  K8S_VIP        Kubernetes API VIP (default: 10.0.0.5)"
    echo "  DNS_UPSTREAM   Upstream DNS server (default: 1.1.1.1)"
    echo ""
    echo "See: docs/opnsense-guide.md Section 3.1"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# Platform detection
OS=$(uname -s)

ping_once() {
    local host="$1"
    local timeout="${2:-3}"
    if [[ "$OS" == "Darwin" ]]; then
        ping -c 1 -t "$timeout" "$host" >/dev/null 2>&1
    else
        ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
    fi
}

record_pass() {
    log_pass "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
    log_fail "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

record_warn() {
    log_warn "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

echo ""
log_info "=== Five-Layer Health Check ==="
log_info "Proxmox: $PROXMOX_HOST | OPNsense: $OPNSENSE_LAN | K8s VIP: $K8S_VIP"
echo ""

# ── Layer 1: Proxmox Host ──────────────────────────────────────────────────────

log_info "── Layer 1: Proxmox Host ──"

if ping_once "$PROXMOX_HOST"; then
    record_pass "Proxmox host ($PROXMOX_HOST) is reachable"
else
    record_fail "Proxmox host ($PROXMOX_HOST) is unreachable"
    echo ""
    log_error "STOP: Proxmox host is down — everything depends on this."
    log_error "Check physical host power, network cable, and main router."
    log_error "See: troubleshooting guide Section 2.1 (dependency chain)"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $WARN_COUNT warnings"
    exit 1
fi

echo ""

# ── Layer 2: OPNsense LAN ──────────────────────────────────────────────────────

log_info "── Layer 2: OPNsense LAN Gateway ──"

if ping_once "$OPNSENSE_LAN"; then
    record_pass "OPNsense LAN gateway ($OPNSENSE_LAN) is reachable"
else
    record_fail "OPNsense LAN gateway ($OPNSENSE_LAN) is unreachable"
    echo ""
    log_error "OPNsense LAN is down. Possible causes:"
    log_error "  - OPNsense VM not running (check via Proxmox console)"
    log_error "  - LAN interface (vtnet1) down"
    log_error "  - DHCP not serving addresses"
    log_error ""
    log_error "Next steps:"
    log_error "  1. Run: scripts/diag-static-ip.sh (assign static IP to reach OPNsense)"
    log_error "  2. Check VM via Proxmox WebGUI: https://$PROXMOX_HOST:8006"
    log_error "  3. See: troubleshooting guide Section 4 and Section 6.3"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $WARN_COUNT warnings"
    exit 1
fi

echo ""

# ── Layer 3: DNS Resolution ─────────────────────────────────────────────────────

log_info "── Layer 3: DNS Resolution ──"

if command -v dig >/dev/null 2>&1; then
    DIG_RESULT=$(dig +short +time=3 +tries=1 @"$OPNSENSE_LAN" google.com 2>/dev/null)
    if [[ -n "$DIG_RESULT" ]]; then
        record_pass "DNS resolution via OPNsense ($OPNSENSE_LAN) works"
    else
        record_fail "DNS resolution via OPNsense ($OPNSENSE_LAN) failed"
        log_error "  Unbound may be down or forwarding is broken."
        log_error "  Run: scripts/diag-dns-matrix.sh for detailed DNS diagnostics"
        log_error "  See: troubleshooting guide Section 8"
    fi
else
    record_warn "dig not found — skipping DNS test (install bind-utils or dnsutils)"
fi

echo ""

# ── Layer 4: Internet Connectivity ──────────────────────────────────────────────

log_info "── Layer 4: Internet Connectivity ──"

if ping_once "8.8.8.8"; then
    record_pass "Internet reachable via ICMP (8.8.8.8)"
else
    record_fail "Internet unreachable via ICMP (8.8.8.8)"
    log_error "  NAT or routing may be broken."
    log_error "  See: troubleshooting guide Section 9 (NAT & Routing Failures)"
fi

if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 https://example.com 2>/dev/null || true)
    if [[ "$HTTP_CODE" == "200" ]]; then
        record_pass "HTTPS connectivity works (example.com → HTTP $HTTP_CODE)"
    else
        record_fail "HTTPS connectivity failed (example.com → HTTP ${HTTP_CODE:-timeout})"
        log_error "  Full-stack issue: DNS + NAT + routing"
        log_error "  See: troubleshooting guide Section 9"
    fi
else
    record_warn "curl not found — skipping HTTPS test"
fi

echo ""

# ── Layer 5: K8s Nodes ──────────────────────────────────────────────────────────

log_info "── Layer 5: Kubernetes Nodes ──"

log_info "Control planes:"
for IP in "${CP_IPS[@]}"; do
    if ping_once "$IP"; then
        record_pass "  Control plane $IP is reachable"
    else
        record_fail "  Control plane $IP is unreachable"
    fi
done

log_info "Workers:"
for IP in "${WORKER_IPS[@]}"; do
    if ping_once "$IP"; then
        record_pass "  Worker $IP is reachable"
    else
        record_fail "  Worker $IP is unreachable"
    fi
done

log_info "K8s API VIP:"
if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 "$K8S_VIP" 6443 2>/dev/null; then
        record_pass "  K8s API VIP ($K8S_VIP:6443) is accepting connections"
    else
        record_fail "  K8s API VIP ($K8S_VIP:6443) is not responding"
        log_error "  If control planes are reachable but VIP is not, this is a Talos issue."
        log_error "  See: troubleshooting guide Section 17.1"
    fi
else
    record_warn "  nc not found — skipping K8s API port test"
fi

echo ""

# ── Summary ─────────────────────────────────────────────────────────────────────

log_info "=== Summary ==="
echo ""
echo -e "${GREEN}Passed:${NC}  $PASS_COUNT"
echo -e "${RED}Failed:${NC}  $FAIL_COUNT"
echo -e "${YELLOW}Warnings:${NC} $WARN_COUNT"
echo ""

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    log_info "All checks passed. Network is healthy."
else
    log_error "Some checks failed. Review output above for next steps."
    echo ""
    log_info "Diagnostic scripts:"
    echo "  scripts/diag-dns-matrix.sh    — Detailed DNS diagnostics"
    echo "  scripts/diag-static-ip.sh     — Emergency static IP assignment"
    echo "  scripts/diag-collect.sh       — Collect full diagnostic data"
    echo ""
    log_info "Reference: docs/opnsense-guide.md"
fi

exit "$FAIL_COUNT"
