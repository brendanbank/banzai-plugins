# Phase 1: Core DDNS Only (no plugin installed)
# Verify PR #9923 works standalone.

section "Phase 1: Core DDNS Only"

# --- Pre-check: plugin should NOT be installed ---
if opn_ssh "pkg info ${PLUGIN_PKG}" >/dev/null 2>&1; then
    info "Plugin ${PLUGIN_PKG} is installed — removing for Phase 1"
    opn_ssh "pkg remove -y ${PLUGIN_PKG}" >/dev/null 2>&1
    opn_kea_reconfigure
fi

if ! opn_ssh "pkg info ${PLUGIN_PKG}" >/dev/null 2>&1; then
    pass "Pre-check: plugin ${PLUGIN_PKG} not installed"
else
    fail "Pre-check: could not remove plugin ${PLUGIN_PKG}"
    return 2>/dev/null || exit 1
fi

# --- 1.1 Find test subnet ---
SUBNET_UUID=$(find_subnet_uuid "$TEST_SUBNET_PATTERN")
if [ -z "$SUBNET_UUID" ]; then
    fail "Could not find DHCPv4 subnet matching ${TEST_SUBNET_PATTERN}"
    return 2>/dev/null || exit 1
fi
info "Test subnet UUID: ${SUBNET_UUID}"

# --- 1.2 Enable core DDNS agent ---
_result=$(opn_post "/api/kea/ddns/set" '{"ddns":{"general":{"enabled":"1"}}}')
_changed=$(echo "$_result" | jq -r '.result // .status // empty' 2>/dev/null)
info "DDNS agent enable result: $_changed"

# --- 1.3 Configure DDNS fields on subnet ---
_subnet_body=$(cat <<EOJSON
{"subnet4":{
    "ddns_forward_zone":"${DDNS_ZONE}",
    "ddns_dns_server":"${DDNS_NS}",
    "ddns_domain_key_name":"${TSIG_KEY_NAME}",
    "ddns_domain_key_secret":"${TSIG_KEY_SECRET}",
    "ddns_domain_key_algorithm":"${TSIG_KEY_ALGORITHM}"
}}
EOJSON
)
_result=$(opn_post "/api/kea/dhcpv4/setSubnet/${SUBNET_UUID}" "$_subnet_body")
_validation=$(echo "$_result" | jq -r '.validations // empty' 2>/dev/null)
if [ -n "$_validation" ] && [ "$_validation" != "{}" ] && [ "$_validation" != "null" ]; then
    fail "Subnet DDNS config validation errors: $_validation"
else
    pass "Core DDNS fields set on subnet"
fi

# --- 1.4 Reconfigure ---
if opn_kea_reconfigure; then
    pass "Kea reconfigure succeeded"
else
    fail "Kea reconfigure failed"
fi

# --- 1.5 Verify kea-dhcp-ddns.conf ---
DDNS_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp-ddns.conf")
if [ -z "$DDNS_CONF_CONTENT" ]; then
    fail "kea-dhcp-ddns.conf does not exist or is empty"
else
    if echo "$DDNS_CONF_CONTENT" | jq . >/dev/null 2>&1; then
        pass "kea-dhcp-ddns.conf is valid JSON"
    else
        fail "kea-dhcp-ddns.conf is not valid JSON"
    fi

    # Check for forward zone
    _fwd_zone=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name // empty' 2>/dev/null)
    if [ "$_fwd_zone" = "${DDNS_ZONE}." ] || [ "$_fwd_zone" = "${DDNS_ZONE}" ]; then
        pass "kea-dhcp-ddns.conf has forward zone: $_fwd_zone"
    else
        fail "kea-dhcp-ddns.conf forward zone: expected ${DDNS_ZONE}, got ${_fwd_zone:-none}"
    fi

    # Check for TSIG key
    _tsig_name=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["tsig-keys"][0].name // empty' 2>/dev/null)
    if [ "$_tsig_name" = "${TSIG_KEY_NAME}" ]; then
        pass "kea-dhcp-ddns.conf has TSIG key: $_tsig_name"
    else
        fail "kea-dhcp-ddns.conf TSIG key: expected ${TSIG_KEY_NAME}, got ${_tsig_name:-none}"
    fi

    # Check for DNS server
    _dns_srv=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["forward-ddns"]["ddns-domains"][0]["dns-servers"][0]["ip-address"] // empty' 2>/dev/null)
    if [ "$_dns_srv" = "${DDNS_NS}" ]; then
        pass "kea-dhcp-ddns.conf DNS server: $_dns_srv"
    else
        fail "kea-dhcp-ddns.conf DNS server: expected ${DDNS_NS}, got ${_dns_srv:-none}"
    fi

    # Check for control-socket (core does NOT have one, plugin does)
    _ctrl_sock=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["control-socket"] // empty' 2>/dev/null)
    if [ -z "$_ctrl_sock" ] || [ "$_ctrl_sock" = "null" ]; then
        info "kea-dhcp-ddns.conf has no control-socket (expected for core)"
    else
        info "kea-dhcp-ddns.conf has control-socket (unexpected for core)"
    fi
fi

# --- 1.6 Verify kea-dhcp4.conf has dhcp-ddns block ---
KEA4_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp4.conf")
if [ -n "$KEA4_CONF_CONTENT" ]; then
    _ddns_enabled=$(echo "$KEA4_CONF_CONTENT" | jq -r \
        '.Dhcp4["dhcp-ddns"]["enable-updates"] // empty' 2>/dev/null)
    if [ "$_ddns_enabled" = "true" ]; then
        pass "kea-dhcp4.conf: dhcp-ddns.enable-updates=true"
    else
        fail "kea-dhcp4.conf: dhcp-ddns.enable-updates=${_ddns_enabled:-missing}"
    fi
else
    fail "kea-dhcp4.conf not found or empty"
fi

# --- 1.7 Verify keactrl.conf ---
KEACTRL_CONTENT=$(opn_cat "/usr/local/etc/kea/keactrl.conf")
if echo "$KEACTRL_CONTENT" | grep -q 'dhcp_ddns=yes'; then
    pass "keactrl.conf: dhcp_ddns=yes"
else
    fail "keactrl.conf: dhcp_ddns not enabled"
fi

# --- 1.8 Verify daemon running ---
if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns daemon is running"
else
    fail "kea-dhcp-ddns daemon is NOT running"
fi

# --- 1.9 Service registration ---
# Core registers DDNS under the shared "kea-dhcp" service name.
# Verify via the running daemon rather than pluginctl output.
_services=$(opn_pluginctl -s 2>/dev/null)
if echo "$_services" | grep -q 'kea-dhcp'; then
    pass "pluginctl -s: kea-dhcp service registered"
else
    fail "pluginctl -s: kea-dhcp service not registered"
fi

# --- 1.10 Save configs for later comparison ---
PHASE1_DDNS_CONF="$DDNS_CONF_CONTENT"
PHASE1_KEA4_CONF="$KEA4_CONF_CONTENT"
PHASE1_KEACTRL="$KEACTRL_CONTENT"
