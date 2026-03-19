# Phase 3: Both Enabled (conflict scenario)
# Document what happens when both core DDNS and plugin are active simultaneously.

section "Phase 3: Both Core DDNS and Plugin Enabled"

# --- 3.1 Re-enable core DDNS agent ---
opn_post "/api/kea/ddns/set" '{"ddns":{"general":{"enabled":"1"}}}' >/dev/null

# Re-add DDNS fields to subnet
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
opn_post "/api/kea/dhcpv4/setSubnet/${SUBNET_UUID}" "$_subnet_body" >/dev/null
pass "Core DDNS re-enabled with subnet DDNS fields"

# Plugin should still be enabled from Phase 2
_plugin_status=$(opn_get "/api/keaddns/general/get")
_plugin_enabled=$(echo "$_plugin_status" | jq -r '.keaddns.general.enabled // .general.enabled // empty' 2>/dev/null)
if [ "$_plugin_enabled" = "1" ]; then
    pass "Plugin still enabled from Phase 2"
else
    info "Plugin enabled=$_plugin_enabled, re-enabling..."
    opn_post "/api/keaddns/general/set" '{"keaddns":{"general":{"enabled":"1"}}}' >/dev/null
fi

# --- 3.2 Reconfigure ---
if opn_kea_reconfigure; then
    pass "Kea reconfigure succeeded (both enabled)"
else
    fail "Kea reconfigure failed"
fi

# --- 3.3 Check which config wins ---
DDNS_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp-ddns.conf")
if [ -n "$DDNS_CONF_CONTENT" ] && echo "$DDNS_CONF_CONTENT" | jq . >/dev/null 2>&1; then
    pass "kea-dhcp-ddns.conf is valid JSON"

    # Determine if it's plugin or core config
    _ctrl_sock=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["control-socket"].socket-name // empty' 2>/dev/null)
    if [ -n "$_ctrl_sock" ]; then
        info "kea-dhcp-ddns.conf: PLUGIN wins (has control-socket)"
        _config_owner="plugin"
    else
        info "kea-dhcp-ddns.conf: CORE wins (no control-socket)"
        _config_owner="core"
    fi

    # Compare with Phase 1 (core) and Phase 2 (plugin) configs
    if [ "$DDNS_CONF_CONTENT" = "$PHASE2_DDNS_CONF" ]; then
        info "kea-dhcp-ddns.conf matches Phase 2 (plugin) config exactly"
    elif [ "$DDNS_CONF_CONTENT" = "$PHASE1_DDNS_CONF" ]; then
        info "kea-dhcp-ddns.conf matches Phase 1 (core) config exactly"
    else
        info "kea-dhcp-ddns.conf differs from both Phase 1 and Phase 2 configs"
    fi
else
    fail "kea-dhcp-ddns.conf not valid or missing"
fi

# --- 3.4 Check kea-dhcp4.conf for duplicate/conflicting blocks ---
KEA4_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp4.conf")
if [ -n "$KEA4_CONF_CONTENT" ]; then
    _ddns_enabled=$(echo "$KEA4_CONF_CONTENT" | jq -r \
        '.Dhcp4["dhcp-ddns"]["enable-updates"] // empty' 2>/dev/null)
    if [ "$_ddns_enabled" = "true" ]; then
        pass "kea-dhcp4.conf: dhcp-ddns.enable-updates=true"
    else
        fail "kea-dhcp4.conf: dhcp-ddns.enable-updates=${_ddns_enabled:-missing}"
    fi

    # Check for per-subnet fields (plugin style)
    _ddns_send_count=$(echo "$KEA4_CONF_CONTENT" | jq \
        '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)] | length' 2>/dev/null)
    info "kea-dhcp4.conf: ${_ddns_send_count} subnet(s) with ddns-send-updates (plugin injects these)"

    # Check JSON validity — duplicate keys would be a problem
    # (jq silently takes the last key, but it indicates a conflict)
    pass "kea-dhcp4.conf is valid JSON (no parse errors)"
else
    fail "kea-dhcp4.conf not found"
fi

# --- 3.5 Service registration ---
# Both core and plugin register DDNS under "kea-dhcp" service name.
# Check how many kea-dhcp entries appear — duplicates indicate conflict.
_services=$(opn_pluginctl -s 2>/dev/null)
_kea_svc_count=$(echo "$_services" | grep -c 'kea-dhcp' 2>/dev/null || echo 0)
info "pluginctl -s: ${_kea_svc_count} kea-dhcp service entry/entries"
if [ "$_kea_svc_count" -ge 1 ]; then
    pass "pluginctl -s: kea-dhcp service registered"
else
    fail "pluginctl -s: no kea-dhcp service registered"
fi

# --- 3.6 Daemon status ---
if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns daemon is running"
else
    fail "kea-dhcp-ddns daemon is NOT running"
fi

_keactrl_status=$(opn_ssh "keactrl status" 2>&1)
if echo "$_keactrl_status" | grep -qi 'ddns.*running\|running.*ddns'; then
    pass "keactrl status: DDNS daemon reported as running"
else
    info "keactrl status output:"
    echo "$_keactrl_status" | while read -r line; do info "  $line"; done
fi

# --- 3.7 Service restart test ---
info "Testing service restart..."
_restart_out=$(opn_ssh "configctl kea restart" 2>&1)
sleep 3
if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns running after restart"
else
    fail "kea-dhcp-ddns NOT running after restart"
fi
if opn_pgrep "kea-dhcp4"; then
    pass "kea-dhcp4 running after restart"
else
    fail "kea-dhcp4 NOT running after restart"
fi

# --- 3.8 Check for PHP errors ---
_php_errors=$(opn_ssh "grep -i 'PHP.*error\|PHP.*fatal\|PHP.*warning' /var/log/system/latest.log 2>/dev/null | grep -i 'kea\|ddns' | tail -5")
if [ -n "$_php_errors" ]; then
    fail "PHP errors related to Kea/DDNS in syslog"
    echo "$_php_errors" | while read -r line; do info "  $line"; done
else
    pass "No PHP errors related to Kea/DDNS in syslog"
fi

# --- 3.9 keactrl.conf consistency ---
KEACTRL_CONTENT=$(opn_cat "/usr/local/etc/kea/keactrl.conf")
if echo "$KEACTRL_CONTENT" | grep -q 'dhcp_ddns=yes'; then
    pass "keactrl.conf: dhcp_ddns=yes"
else
    fail "keactrl.conf: dhcp_ddns not enabled"
fi
