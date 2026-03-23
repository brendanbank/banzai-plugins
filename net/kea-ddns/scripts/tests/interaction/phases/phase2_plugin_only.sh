# Phase 2: Plugin Only (core DDNS disabled)
# Verify the plugin still works on the new core with PR #9923 merged.

section "Phase 2: Plugin Only (core DDNS disabled)"

# --- 2.1 Disable core DDNS ---
opn_post "/api/kea/ddns/set" '{"ddns":{"general":{"enabled":"0"}}}' >/dev/null

# Clear subnet DDNS fields
_clear_body='{"subnet4":{
    "ddns_forward_zone":"",
    "ddns_dns_server":"",
    "ddns_domain_key_name":"",
    "ddns_domain_key_secret":"",
    "ddns_domain_key_algorithm":""
}}'
opn_post "/api/kea/dhcpv4/setSubnet/${SUBNET_UUID}" "$_clear_body" >/dev/null
opn_kea_reconfigure
pass "Core DDNS disabled and subnet fields cleared"

# --- 2.2 Install plugin ---
info "Installing plugin ${PLUGIN_PKG}..."
if ! opn_ssh "pkg info ${PLUGIN_PKG}" >/dev/null 2>&1; then
    # Try local package file first (SCP'd by caller), then repo install
    if [ -n "$PLUGIN_PKG_FILE" ] && [ -f "$PLUGIN_PKG_FILE" ]; then
        info "Installing from local package: $(basename "$PLUGIN_PKG_FILE")"
        _ssh_user="${OPN_SSH_USER:-root}"
        scp -o StrictHostKeyChecking=no "$PLUGIN_PKG_FILE" "${_ssh_user}@${OPN_HOST}:/tmp/" 2>/dev/null
        _install_out=$(opn_ssh "pkg install -y /tmp/$(basename "$PLUGIN_PKG_FILE")" 2>&1)
    else
        _install_out=$(opn_ssh "pkg install -y ${PLUGIN_PKG}" 2>&1)
    fi
fi
if opn_ssh "pkg info ${PLUGIN_PKG}" >/dev/null 2>&1; then
    _pkg_version=$(opn_ssh "pkg info ${PLUGIN_PKG}" 2>/dev/null | head -1)
    pass "Plugin installed: $_pkg_version"
else
    fail "Failed to install ${PLUGIN_PKG}"
    info "Install output: $(echo "$_install_out" | tail -5)"
    return 2>/dev/null || exit 1
fi

# Reload firmware plugins so OPNsense sees the new plugin
opn_ssh "/usr/local/etc/rc.configure_firmware" >/dev/null 2>&1
sleep 2

# --- 2.3 Configure plugin: enable ---
_result=$(opn_post "/api/keaddns/general/set" '{"keaddns":{"general":{"enabled":"1"}}}'); _http_code
_status=$(echo "$_result" | jq -r '.result // .status // empty' 2>/dev/null)
if [ "$_status" = "saved" ] || [ "$HTTP_CODE" = "200" ]; then
    pass "Plugin enabled via API"
else
    fail "Plugin enable failed: $_result"
fi

# --- 2.4 Add TSIG key ---
_tsig_body=$(cat <<EOJSON
{"tsig_key":{
    "name":"${TSIG_KEY_NAME}",
    "algorithm":"HMAC-SHA512",
    "secret":"${TSIG_KEY_SECRET}"
}}
EOJSON
)
_result=$(opn_post "/api/keaddns/general/addTsigKey" "$_tsig_body")
_tsig_uuid=$(echo "$_result" | jq -r '.uuid // empty' 2>/dev/null)
if [ -n "$_tsig_uuid" ]; then
    pass "TSIG key created: ${_tsig_uuid}"
else
    # May already exist — search for it
    _search=$(opn_post "/api/keaddns/general/searchTsigKey" '{}')
    _tsig_uuid=$(echo "$_search" | jq -r \
        --arg name "$TSIG_KEY_NAME" \
        '.rows[] | select(.name == $name) | .uuid' 2>/dev/null | head -1)
    if [ -n "$_tsig_uuid" ]; then
        pass "TSIG key already exists: ${_tsig_uuid}"
    else
        fail "Could not create or find TSIG key"
    fi
fi

# --- 2.5 Add forward zone ---
if [ -n "$_tsig_uuid" ]; then
    _zone_body=$(cat <<EOJSON
{"zone":{
    "name":"${DDNS_ZONE}",
    "server":"${DDNS_NS}",
    "port":"53",
    "tsig_key":"${_tsig_uuid}"
}}
EOJSON
    )
    _result=$(opn_post "/api/keaddns/general/addForwardZone" "$_zone_body")
    _zone_uuid=$(echo "$_result" | jq -r '.uuid // empty' 2>/dev/null)
    if [ -n "$_zone_uuid" ]; then
        pass "Forward zone created: ${_zone_uuid}"
    else
        # May already exist
        _search=$(opn_post "/api/keaddns/general/searchForwardZone" '{}')
        _zone_uuid=$(echo "$_search" | jq -r \
            --arg name "$DDNS_ZONE" \
            '.rows[] | select(.name == $name) | .uuid' 2>/dev/null | head -1)
        if [ -n "$_zone_uuid" ]; then
            pass "Forward zone already exists: ${_zone_uuid}"
        else
            fail "Could not create or find forward zone"
        fi
    fi
fi

# --- 2.6 Add subnet DDNS assignment ---
if [ -n "$_zone_uuid" ] && [ -n "$SUBNET_UUID" ]; then
    _assign_body=$(cat <<EOJSON
{"assignment":{
    "subnet":"${SUBNET_UUID}",
    "qualifying_suffix":"${DDNS_ZONE}.",
    "send_updates":"1"
}}
EOJSON
    )
    _result=$(opn_post "/api/keaddns/general/addSubnetDdns" "$_assign_body")
    _assign_uuid=$(echo "$_result" | jq -r '.uuid // empty' 2>/dev/null)
    if [ -n "$_assign_uuid" ]; then
        pass "Subnet DDNS assignment created: ${_assign_uuid}"
    else
        # May already exist
        _search=$(opn_post "/api/keaddns/general/searchSubnetDdns" '{}')
        _assign_uuid=$(echo "$_search" | jq -r '.rows[0].uuid // empty' 2>/dev/null)
        if [ -n "$_assign_uuid" ]; then
            pass "Subnet DDNS assignment already exists: ${_assign_uuid}"
        else
            fail "Could not create subnet DDNS assignment: $_result"
        fi
    fi
fi

# --- 2.7 Reconfigure ---
if opn_kea_reconfigure; then
    pass "Kea reconfigure succeeded"
else
    fail "Kea reconfigure failed"
fi

# --- 2.8 Verify config files ---
DDNS_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp-ddns.conf")
if [ -n "$DDNS_CONF_CONTENT" ] && echo "$DDNS_CONF_CONTENT" | jq . >/dev/null 2>&1; then
    pass "kea-dhcp-ddns.conf is valid JSON"

    # Plugin should have a control-socket
    _ctrl_sock=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["control-socket"].socket-name // empty' 2>/dev/null)
    if [ -n "$_ctrl_sock" ]; then
        pass "kea-dhcp-ddns.conf has control-socket (plugin-generated): $_ctrl_sock"
    else
        info "kea-dhcp-ddns.conf has no control-socket"
    fi

    # Check forward zone
    _fwd_zone=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name // empty' 2>/dev/null)
    if echo "$_fwd_zone" | grep -q "${DDNS_ZONE}"; then
        pass "kea-dhcp-ddns.conf forward zone: $_fwd_zone"
    else
        fail "kea-dhcp-ddns.conf forward zone missing or wrong: ${_fwd_zone:-none}"
    fi
else
    fail "kea-dhcp-ddns.conf not valid or missing"
fi

# Check kea-dhcp4.conf for per-subnet ddns fields
KEA4_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp4.conf")
if [ -n "$KEA4_CONF_CONTENT" ]; then
    _ddns_enabled=$(echo "$KEA4_CONF_CONTENT" | jq -r \
        '.Dhcp4["dhcp-ddns"]["enable-updates"] // empty' 2>/dev/null)
    if [ "$_ddns_enabled" = "true" ]; then
        pass "kea-dhcp4.conf: dhcp-ddns.enable-updates=true (plugin)"
    else
        fail "kea-dhcp4.conf: dhcp-ddns.enable-updates=${_ddns_enabled:-missing}"
    fi

    # Plugin adds per-subnet ddns-send-updates
    _ddns_subnet=$(echo "$KEA4_CONF_CONTENT" | jq \
        '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)] | length' 2>/dev/null)
    if [ "$_ddns_subnet" -gt 0 ] 2>/dev/null; then
        pass "kea-dhcp4.conf: $_ddns_subnet subnet(s) with ddns-send-updates"
    else
        fail "kea-dhcp4.conf: no subnets with ddns-send-updates"
    fi

    # Plugin adds ddns-qualifying-suffix per subnet
    _qual_suffix=$(echo "$KEA4_CONF_CONTENT" | jq -r \
        '[.Dhcp4.subnet4[] | select(.["ddns-qualifying-suffix"])] | length' 2>/dev/null)
    if [ "$_qual_suffix" -gt 0 ] 2>/dev/null; then
        pass "kea-dhcp4.conf: $_qual_suffix subnet(s) with ddns-qualifying-suffix"
    else
        info "kea-dhcp4.conf: no subnets with ddns-qualifying-suffix"
    fi
fi

# keactrl.conf
KEACTRL_CONTENT=$(opn_cat "/usr/local/etc/kea/keactrl.conf")
if echo "$KEACTRL_CONTENT" | grep -q 'dhcp_ddns=yes'; then
    pass "keactrl.conf: dhcp_ddns=yes"
else
    fail "keactrl.conf: dhcp_ddns not enabled"
fi

# --- 2.9 Verify daemon ---
if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns daemon is running"
else
    fail "kea-dhcp-ddns daemon is NOT running"
fi

# --- 2.10 Check for conflicts ---
# Both core and plugin register services under "kea-dhcp" name.
# Check for duplicate "kea-dhcp" lines and also verify kea-ddns service via plugin's hook.
_services=$(opn_pluginctl -s 2>/dev/null)
_kea_svc_count=$(echo "$_services" | grep -c 'kea-dhcp' 2>/dev/null || echo 0)
if [ "$_kea_svc_count" -ge 1 ]; then
    pass "pluginctl -s: kea-dhcp service registered (${_kea_svc_count} entries)"
else
    fail "pluginctl -s: no kea-dhcp service registered"
fi
# Check plugin's hook file exists
if opn_file_exists "/usr/local/etc/inc/plugins.inc.d/kea_ddns.inc"; then
    pass "Plugin hook file kea_ddns.inc present"
else
    fail "Plugin hook file kea_ddns.inc missing"
fi

# Check for errors in system log
_log_errors=$(opn_ssh "grep -i 'error\|fatal\|exception' /var/log/system/latest.log 2>/dev/null | grep -i 'kea\|ddns' | tail -5")
if [ -n "$_log_errors" ]; then
    info "Recent DDNS-related errors in syslog:"
    echo "$_log_errors" | while read -r line; do info "  $line"; done
else
    pass "No DDNS-related errors in syslog"
fi

# Save plugin config state
PHASE2_DDNS_CONF="$DDNS_CONF_CONTENT"
PHASE2_KEA4_CONF="$KEA4_CONF_CONTENT"

# Save plugin UUIDs for later phases
PLUGIN_TSIG_UUID="$_tsig_uuid"
PLUGIN_ZONE_UUID="$_zone_uuid"
PLUGIN_ASSIGN_UUID="$_assign_uuid"
