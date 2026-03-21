#!/bin/bash
set -euo pipefail

# Homelab Diagnostic: DNS Test Matrix
# Maps to: docs/opnsense-troubleshooting-guide.md Section 8.5
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

# Configuration
OPNSENSE_LAN="${OPNSENSE_LAN:-10.0.0.1}"
DNS_UPSTREAM="${DNS_UPSTREAM:-1.1.1.1}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-talos-cp-1.homelab.local}"
LOCAL_EXPECTED_IP="${LOCAL_EXPECTED_IP:-10.0.0.10}"

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "DNS diagnostic test matrix — runs all 6 DNS tests from the troubleshooting guide."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  OPNSENSE_LAN       OPNsense LAN IP (default: 10.0.0.1)"
    echo "  DNS_UPSTREAM       Upstream DNS server (default: 1.1.1.1)"
    echo "  LOCAL_HOSTNAME     Local hostname to test (default: talos-cp-1.homelab.local)"
    echo "  LOCAL_EXPECTED_IP  Expected IP for local hostname (default: 10.0.0.10)"
    echo ""
    echo "See: docs/opnsense-troubleshooting-guide.md Section 8.5"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

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

# Pre-check: dig must be available
if ! command -v dig >/dev/null 2>&1; then
    log_error "dig is required but not found."
    echo ""
    echo "Install it:"
    echo "  macOS:   brew install bind        (or: dig is usually pre-installed)"
    echo "  Ubuntu:  sudo apt install dnsutils"
    echo "  Fedora:  sudo dnf install bind-utils"
    echo "  Arch:    sudo pacman -S bind"
    exit 1
fi

echo ""
log_info "=== DNS Test Matrix ==="
log_info "OPNsense: $OPNSENSE_LAN | Upstream: $DNS_UPSTREAM"
echo ""

# ── Test 1: Basic forwarding ───────────────────────────────────────────────────

log_info "── Test 1: Basic DNS Forwarding ──"
log_info "Command: dig @$OPNSENSE_LAN google.com"

RESULT=$(dig +short +time=5 +tries=1 @"$OPNSENSE_LAN" google.com 2>/dev/null)
if [[ -n "$RESULT" ]]; then
    record_pass "Unbound is running and forwarding (resolved to: $(echo "$RESULT" | head -1))"
else
    record_fail "Unbound is down or forwarding is broken"
    log_error "  → Check: service unbound status (on OPNsense console)"
    log_error "  → See: troubleshooting guide Section 8.1"
fi
echo ""

# ── Test 2: Upstream DNS reachability ──────────────────────────────────────────

log_info "── Test 2: Upstream DNS Reachability ──"
log_info "Command: dig @$DNS_UPSTREAM google.com"

RESULT=$(dig +short +time=5 +tries=1 @"$DNS_UPSTREAM" google.com 2>/dev/null)
if [[ -n "$RESULT" ]]; then
    record_pass "Upstream DNS ($DNS_UPSTREAM) reachable — WAN and NAT are working"
else
    record_fail "Upstream DNS ($DNS_UPSTREAM) unreachable — WAN or NAT issue, not DNS"
    log_error "  → If Test 1 also failed: problem is WAN connectivity, not Unbound"
    log_error "  → See: troubleshooting guide Section 9 (NAT & Routing)"
fi
echo ""

# ── Test 3: Host overrides (local DNS) ─────────────────────────────────────────

log_info "── Test 3: Host Overrides (Local DNS) ──"
log_info "Command: dig @$OPNSENSE_LAN $LOCAL_HOSTNAME"

RESULT=$(dig +short +time=5 +tries=1 @"$OPNSENSE_LAN" "$LOCAL_HOSTNAME" 2>/dev/null)
if [[ -n "$RESULT" ]]; then
    if [[ "$RESULT" == "$LOCAL_EXPECTED_IP" ]]; then
        record_pass "Host override works ($LOCAL_HOSTNAME → $RESULT)"
    else
        record_warn "Host override returned unexpected IP ($LOCAL_HOSTNAME → $RESULT, expected $LOCAL_EXPECTED_IP)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    record_fail "Host override not found ($LOCAL_HOSTNAME → NXDOMAIN)"
    log_error "  → Host overrides missing in Unbound configuration"
    log_error "  → Check: WebGUI → Services → Unbound DNS → Host Overrides"
    log_error "  → See: troubleshooting guide Section 8.3"
fi
echo ""

# ── Test 4: DNSSEC validation ──────────────────────────────────────────────────

log_info "── Test 4: DNSSEC Validation ──"
log_info "Command: dig @$OPNSENSE_LAN google.com +dnssec"

DNSSEC_OUTPUT=$(dig +time=5 +tries=1 @"$OPNSENSE_LAN" google.com +dnssec 2>/dev/null)
if echo "$DNSSEC_OUTPUT" | grep -q "ad"; then
    record_pass "DNSSEC validation is working (AD flag present)"
else
    ANSWER=$(echo "$DNSSEC_OUTPUT" | grep -c "ANSWER SECTION" || true)
    if [[ "$ANSWER" -gt 0 ]]; then
        record_warn "DNS works but DNSSEC AD flag not set (DNSSEC may be disabled or not validating)"
    else
        record_fail "DNSSEC query failed entirely"
        log_error "  → See: troubleshooting guide Section 8.2 (DNSSEC failure)"
    fi
fi
echo ""

# ── Test 5: TCP DNS ────────────────────────────────────────────────────────────

log_info "── Test 5: TCP DNS (port 53/tcp) ──"
log_info "Command: dig @$OPNSENSE_LAN google.com +tcp"

RESULT=$(dig +short +time=5 +tries=1 +tcp @"$OPNSENSE_LAN" google.com 2>/dev/null)
if [[ -n "$RESULT" ]]; then
    record_pass "TCP DNS works (port 53/tcp is open)"
else
    record_fail "TCP DNS failed — firewall may be blocking TCP/53"
    log_error "  → Some DNS responses require TCP (large records, zone transfers)"
    log_error "  → Check: firewall rules for TCP port 53 on LAN interface"
fi
echo ""

# ── Test 6: Reachability vs DNS ────────────────────────────────────────────────

log_info "── Test 6: Reachability vs DNS (separate concerns) ──"

OS=$(uname -s)
ping_once() {
    if [[ "$OS" == "Darwin" ]]; then
        ping -c 1 -t 3 "$1" >/dev/null 2>&1
    else
        ping -c 1 -W 3 "$1" >/dev/null 2>&1
    fi
}

PING_OK=false
DIG_OK=false

if ping_once "$OPNSENSE_LAN"; then
    PING_OK=true
fi

DIG_RESULT=$(dig +short +time=3 +tries=1 @"$OPNSENSE_LAN" google.com 2>/dev/null)
if [[ -n "$DIG_RESULT" ]]; then
    DIG_OK=true
fi

if $PING_OK && $DIG_OK; then
    record_pass "OPNsense is reachable AND DNS is working"
elif $PING_OK && ! $DIG_OK; then
    record_fail "OPNsense is reachable but DNS is NOT working — port 53 may be blocked or Unbound is down"
    log_error "  → Ping works, so the network path is fine"
    log_error "  → Problem is specifically the DNS service"
    log_error "  → Check: sockstat -4 -l | grep :53 (on OPNsense)"
elif ! $PING_OK && ! $DIG_OK; then
    record_fail "OPNsense is NOT reachable — network issue, not DNS"
    log_error "  → Cannot even ping OPNsense — fix network first"
    log_error "  → Run: scripts/diag-health-check.sh for full triage"
else
    record_warn "OPNsense not pingable but DNS works (ICMP may be blocked)"
fi
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────────

log_info "=== Summary ==="
echo ""
echo -e "${GREEN}Passed:${NC}  $PASS_COUNT"
echo -e "${RED}Failed:${NC}  $FAIL_COUNT"
echo -e "${YELLOW}Warnings:${NC} $WARN_COUNT"
echo ""

# Diagnosis summary
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    log_info "All DNS tests passed. DNS is healthy."
else
    log_error "DNS issues detected. Diagnosis:"
    echo ""
    echo "  Common patterns:"
    echo "    Tests 1+2 fail  → Network/WAN issue, not DNS (Section 9)"
    echo "    Test 1 fails, 2 passes → Unbound is down (Section 8.1)"
    echo "    Tests 1+2 pass, 3 fails → Host overrides missing (Section 8.3)"
    echo "    Test 5 fails, others pass → TCP/53 blocked (check firewall)"
    echo "    Test 6 shows reachable but no DNS → Unbound service issue (Section 8.1)"
    echo ""
    log_info "Reference: docs/opnsense-troubleshooting-guide.md Section 8"
fi

exit "$FAIL_COUNT"
