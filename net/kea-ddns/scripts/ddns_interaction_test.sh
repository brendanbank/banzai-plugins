#!/bin/sh

# Core DDNS (PR #9923) vs banzai-plugins kea-ddns Interaction Test
#
# Tests all five scenarios:
#   Phase 1: Core DDNS only (no plugin)
#   Phase 2: Plugin only (core DDNS disabled)
#   Phase 3: Both enabled (conflict scenario)
#   Phase 4: Core enabled, plugin disabled
#   Phase 5: Cleanup and edge cases
#
# Usage:
#   ./scripts/ddns_interaction_test.sh                    # run all phases
#   ./scripts/ddns_interaction_test.sh 1                  # run phase 1 only
#   ./scripts/ddns_interaction_test.sh 1 2                # run phases 1 and 2
#   ./scripts/ddns_interaction_test.sh --check            # connectivity check only
#
# Requires:
#   - curl, jq, ssh, dig (on workstation)
#   - API key file in key:secret format
#   - SSH access to the OPNsense host
#   - Config file: scripts/tests/interaction/ddns_interaction_test.conf

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/tests/interaction"

# Load helpers
. "$TEST_DIR/opnapi.sh"

# Load config
CONF_FILE="$TEST_DIR/ddns_interaction_test.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found: $CONF_FILE"
    echo "Copy scripts/tests/interaction/ddns_interaction_test.conf.sample and edit it."
    exit 1
fi
. "$CONF_FILE"

# Validate required config
for var in OPN_HOST OPN_API_KEY_FILE DDNS_ZONE DDNS_NS TSIG_KEY_NAME \
           TSIG_KEY_ALGORITHM TSIG_KEY_SECRET TEST_SUBNET_PATTERN PLUGIN_PKG; do
    eval _val="\$$var"
    if [ -z "$_val" ]; then
        echo "ERROR: Required config variable not set: $var"
        exit 1
    fi
done

# Load API credentials
load_api_key "$OPN_API_KEY_FILE"

# Preflight checks
for cmd in curl jq ssh dig; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
done

echo ""
echo "DDNS Interaction Test: Core (PR #9923) vs Plugin (os-kea-ddns)"
echo "=============================================================="
echo ""
info "Target: ${OPN_HOST}"
info "Zone: ${DDNS_ZONE}"
info "NS: ${DDNS_NS}"
info "Plugin: ${PLUGIN_PKG}"
echo ""

# --- Connectivity check ---
section "Connectivity"

# API access
_version=$(opn_get "/api/core/firmware/status"); _http_code
_fw_version=$(echo "$_version" | jq -r '.product_version // .product.product_version // empty' 2>/dev/null)
if [ -n "$_fw_version" ]; then
    pass "API access OK (OPNsense ${_fw_version})"
else
    # Try alternative endpoint
    _version=$(opn_get "/api/core/firmware/info"); _http_code
    _fw_version=$(echo "$_version" | jq -r '.product_version // empty' 2>/dev/null)
    if [ -n "$_fw_version" ]; then
        pass "API access OK (OPNsense ${_fw_version})"
    else
        fail "API access failed (HTTP ${HTTP_CODE})"
        echo "Cannot proceed without API access." >&2
        exit 1
    fi
fi

# SSH access
if opn_ssh "true" 2>/dev/null; then
    pass "SSH access OK"
else
    fail "SSH access to ${OPN_HOST} failed"
    echo "SSH is required for config file inspection. Some tests will fail." >&2
fi

# Kea DHCPv4 running
if opn_pgrep "kea-dhcp4"; then
    pass "kea-dhcp4 daemon running"
else
    fail "kea-dhcp4 daemon NOT running"
    echo "Kea DHCPv4 must be running. Cannot proceed." >&2
    exit 1
fi

# Check core DDNS API exists (PR #9923 merged)
_ddns_api=$(opn_get "/api/kea/ddns/get"); _http_code
if [ "$HTTP_CODE" = "200" ] && echo "$_ddns_api" | jq . >/dev/null 2>&1; then
    pass "Core DDNS API available (/api/kea/ddns/get)"
else
    fail "Core DDNS API not available — PR #9923 may not be merged"
    echo "Cannot proceed without core DDNS support." >&2
    exit 1
fi

# Find test subnet
SUBNET_UUID=$(find_subnet_uuid "$TEST_SUBNET_PATTERN")
if [ -n "$SUBNET_UUID" ]; then
    pass "Test subnet found: ${SUBNET_UUID}"
else
    fail "No DHCPv4 subnet matching '${TEST_SUBNET_PATTERN}'"
    echo "Configure a Kea DHCPv4 subnet on the test VLAN first." >&2
    exit 1
fi

# --check mode: stop after connectivity
if [ "$1" = "--check" ]; then
    results_summary
    exit $?
fi

# Determine which phases to run
PHASES="${*:-1 2 3 4 5}"

# Initialize phase state variables
PHASE1_DDNS_CONF=""
PHASE1_KEA4_CONF=""
PHASE1_KEACTRL=""
PHASE2_DDNS_CONF=""
PHASE2_KEA4_CONF=""
PLUGIN_TSIG_UUID=""
PLUGIN_ZONE_UUID=""
PLUGIN_ASSIGN_UUID=""

# Run requested phases
for phase in $PHASES; do
    case "$phase" in
        1) . "$TEST_DIR/phases/phase1_core_ddns.sh" ;;
        2) . "$TEST_DIR/phases/phase2_plugin_only.sh" ;;
        3) . "$TEST_DIR/phases/phase3_both_enabled.sh" ;;
        4) . "$TEST_DIR/phases/phase4_plugin_disabled.sh" ;;
        5) . "$TEST_DIR/phases/phase5_cleanup.sh" ;;
        *) echo "Unknown phase: $phase (valid: 1-5)" >&2 ;;
    esac
done

# --- Summary ---
results_summary
exit $?
