# Phase 4: Core Enabled, Plugin Installed but Disabled
# Verify the plugin doesn't interfere when disabled.

section "Phase 4: Core Enabled, Plugin Disabled"

# --- 4.1 Disable plugin ---
_result=$(opn_post "/api/keaddns/general/set" '{"keaddns":{"general":{"enabled":"0"}}}'); _http_code
_status=$(echo "$_result" | jq -r '.result // .status // empty' 2>/dev/null)
if [ "$_status" = "saved" ] || [ "$HTTP_CODE" = "200" ]; then
    pass "Plugin disabled via API"
else
    fail "Plugin disable failed: $_result"
fi

# Core DDNS should still be enabled with subnet fields from Phase 3
_core_status=$(opn_get "/api/kea/ddns/get")
_core_enabled=$(echo "$_core_status" | jq -r '.ddns.general.enabled // empty' 2>/dev/null)
if [ "$_core_enabled" = "1" ]; then
    pass "Core DDNS still enabled"
else
    info "Core DDNS enabled=$_core_enabled, re-enabling..."
    opn_post "/api/kea/ddns/set" '{"ddns":{"general":{"enabled":"1"}}}' >/dev/null
fi

# --- 4.2 Reconfigure ---
if opn_kea_reconfigure; then
    pass "Kea reconfigure succeeded"
else
    fail "Kea reconfigure failed"
fi

# --- 4.3 Verify core config is intact ---
DDNS_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp-ddns.conf")
if [ -n "$DDNS_CONF_CONTENT" ] && echo "$DDNS_CONF_CONTENT" | jq . >/dev/null 2>&1; then
    pass "kea-dhcp-ddns.conf is valid JSON"

    # Should be core's config (no control-socket)
    _ctrl_sock=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["control-socket"].socket-name // empty' 2>/dev/null)

    # When plugin is disabled, its kea_sync hook should be a no-op
    # So the config should be core-generated
    if [ -z "$_ctrl_sock" ] || [ "$_ctrl_sock" = "null" ]; then
        pass "kea-dhcp-ddns.conf: core-generated (no control-socket)"
    else
        info "kea-dhcp-ddns.conf: still has control-socket — plugin hook may not be fully no-op"
        info "  socket: $_ctrl_sock"
    fi

    # Forward zone should still be present (from core config)
    _fwd_zone=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name // empty' 2>/dev/null)
    if echo "$_fwd_zone" | grep -q "${DDNS_ZONE}"; then
        pass "kea-dhcp-ddns.conf: forward zone intact: $_fwd_zone"
    else
        fail "kea-dhcp-ddns.conf: forward zone missing (expected ${DDNS_ZONE})"
    fi
else
    fail "kea-dhcp-ddns.conf not valid or missing"
fi

# --- 4.4 Verify kea-dhcp4.conf ---
KEA4_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp4.conf")
if [ -n "$KEA4_CONF_CONTENT" ]; then
    _ddns_enabled=$(echo "$KEA4_CONF_CONTENT" | jq -r \
        '.Dhcp4["dhcp-ddns"]["enable-updates"] // empty' 2>/dev/null)
    if [ "$_ddns_enabled" = "true" ]; then
        pass "kea-dhcp4.conf: dhcp-ddns.enable-updates=true (core)"
    else
        fail "kea-dhcp4.conf: dhcp-ddns.enable-updates=${_ddns_enabled:-missing}"
    fi

    # Plugin-added per-subnet fields should NOT be present when plugin is disabled
    _ddns_send_count=$(echo "$KEA4_CONF_CONTENT" | jq \
        '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)] | length' 2>/dev/null)
    if [ "$_ddns_send_count" -eq 0 ] 2>/dev/null; then
        pass "kea-dhcp4.conf: no plugin-added ddns-send-updates (plugin is inert)"
    else
        info "kea-dhcp4.conf: ${_ddns_send_count} subnet(s) with ddns-send-updates"
        info "  (may be from core or residual plugin config)"
    fi
else
    fail "kea-dhcp4.conf not found"
fi

# --- 4.5 keactrl ---
# BUG: When plugin is disabled, kea_ddns_configure_do() calls
# kea_ddns_update_keactrl(false), which overwrites core's dhcp_ddns=yes
# with dhcp_ddns=no. The disabled plugin should not touch keactrl.conf.
KEACTRL_CONTENT=$(opn_cat "/usr/local/etc/kea/keactrl.conf")
if echo "$KEACTRL_CONTENT" | grep -q 'dhcp_ddns=yes'; then
    pass "keactrl.conf: dhcp_ddns=yes"
else
    fail "keactrl.conf: dhcp_ddns=no (disabled plugin overwrites core — BUG)"
fi

# --- 4.6 Daemon running ---
if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns daemon is running (core-managed)"
else
    fail "kea-dhcp-ddns daemon NOT running (caused by keactrl.conf overwrite)"
fi

# --- 4.7 Service registration ---
_services=$(opn_pluginctl -s 2>/dev/null)
_kea_count=$(echo "$_services" | grep -c 'kea-dhcp' 2>/dev/null || true)
info "pluginctl -s: ${_kea_count} kea-dhcp entry/entries"
