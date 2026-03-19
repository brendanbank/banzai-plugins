# Phase 5: Cleanup and Edge Cases
# Uninstall plugin, verify clean state, check edge cases.

section "Phase 5: Cleanup and Edge Cases"

# --- 5.1 Service registration before uninstall ---
info "Checking service registration before uninstall..."
_services_before=$(opn_pluginctl -s 2>/dev/null)
_kea_count_before=$(echo "$_services_before" | grep -c 'kea-dhcp' 2>/dev/null || true)
info "kea-dhcp registrations before uninstall: ${_kea_count_before}"

# --- 5.2 Uninstall plugin ---
info "Removing plugin ${PLUGIN_PKG}..."
opn_ssh "pkg remove -y ${PLUGIN_PKG}" >/dev/null 2>&1
opn_ssh "/usr/local/etc/rc.configure_firmware" >/dev/null 2>&1
sleep 2

if ! opn_ssh "pkg info ${PLUGIN_PKG}" >/dev/null 2>&1; then
    pass "Plugin ${PLUGIN_PKG} removed"
else
    fail "Plugin ${PLUGIN_PKG} still installed after removal"
fi

# --- 5.3 Reconfigure after uninstall ---
if opn_kea_reconfigure; then
    pass "Kea reconfigure succeeded after plugin removal"
else
    fail "Kea reconfigure failed after plugin removal"
fi

# --- 5.4 Core DDNS should continue working ---
DDNS_CONF_CONTENT=$(opn_cat "/usr/local/etc/kea/kea-dhcp-ddns.conf")
if [ -n "$DDNS_CONF_CONTENT" ] && echo "$DDNS_CONF_CONTENT" | jq . >/dev/null 2>&1; then
    pass "kea-dhcp-ddns.conf still valid after plugin removal"

    _fwd_zone=$(echo "$DDNS_CONF_CONTENT" | jq -r \
        '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name // empty' 2>/dev/null)
    if echo "$_fwd_zone" | grep -q "${DDNS_ZONE}"; then
        pass "Core DDNS config intact: forward zone $_fwd_zone"
    else
        fail "Core DDNS forward zone lost after plugin removal"
    fi
else
    fail "kea-dhcp-ddns.conf missing or invalid after plugin removal"
fi

if opn_pgrep "kea-dhcp-ddns"; then
    pass "kea-dhcp-ddns daemon running after plugin removal"
else
    fail "kea-dhcp-ddns daemon NOT running after plugin removal"
fi

# --- 5.5 No orphaned service entries ---
_services_after=$(opn_pluginctl -s 2>/dev/null)
_kea_count_after=$(echo "$_services_after" | grep -c 'kea-dhcp' 2>/dev/null || echo 0)
info "pluginctl -s: ${_kea_count_after} kea-dhcp entry/entries after uninstall"
if [ "$_kea_count_after" -ge 1 ]; then
    pass "pluginctl -s: kea-dhcp service still registered (core)"
else
    info "pluginctl -s: no kea-dhcp entry (may be expected if DHCPv4 disabled)"
fi

# Check plugin hook file is removed
if opn_file_exists "/usr/local/etc/inc/plugins.inc.d/kea_ddns.inc"; then
    fail "Plugin hook file kea_ddns.inc still present after uninstall"
else
    pass "Plugin hook file kea_ddns.inc removed"
fi

# --- 5.6 Edge case: TSIG key format ---
section "Edge Cases"

info "Checking TSIG key format in core config..."
_tsig_algo=$(echo "$DDNS_CONF_CONTENT" | jq -r \
    '.DhcpDdns["tsig-keys"][0].algorithm // empty' 2>/dev/null)
_tsig_name=$(echo "$DDNS_CONF_CONTENT" | jq -r \
    '.DhcpDdns["tsig-keys"][0].name // empty' 2>/dev/null)
_tsig_secret=$(echo "$DDNS_CONF_CONTENT" | jq -r \
    '.DhcpDdns["tsig-keys"][0].secret // empty' 2>/dev/null)

if [ -n "$_tsig_name" ] && [ -n "$_tsig_algo" ] && [ -n "$_tsig_secret" ]; then
    pass "Core TSIG key: name=$_tsig_name, algorithm=$_tsig_algo"

    # Kea expects algorithm names like "HMAC-SHA512" or "hmac-sha512"
    if echo "$_tsig_algo" | grep -qi 'hmac'; then
        pass "TSIG algorithm format valid for Kea: $_tsig_algo"
    else
        fail "TSIG algorithm format may be invalid: $_tsig_algo"
    fi

    # Secret should be base64
    if echo "$_tsig_secret" | grep -qE '^[A-Za-z0-9+/=]+$'; then
        pass "TSIG secret is base64-encoded"
    else
        fail "TSIG secret does not look like base64"
    fi
else
    fail "TSIG key incomplete: name=${_tsig_name:-missing} algo=${_tsig_algo:-missing}"
fi

# --- 5.7 No errors in logs ---
_recent_errors=$(opn_ssh "grep -i 'error\|fatal' /var/log/system/latest.log 2>/dev/null | grep -i 'kea\|ddns' | tail -3")
if [ -n "$_recent_errors" ]; then
    info "Recent DDNS-related log messages:"
    echo "$_recent_errors" | while read -r line; do info "  $line"; done
else
    pass "No DDNS-related errors in syslog"
fi

# --- 5.8 Final cleanup: disable core DDNS and clear subnet fields ---
section "Final Cleanup"

opn_post "/api/kea/ddns/set" '{"ddns":{"general":{"enabled":"0"}}}' >/dev/null

_clear_body='{"subnet4":{
    "ddns_forward_zone":"",
    "ddns_dns_server":"",
    "ddns_domain_key_name":"",
    "ddns_domain_key_secret":"",
    "ddns_domain_key_algorithm":""
}}'
opn_post "/api/kea/dhcpv4/setSubnet/${SUBNET_UUID}" "$_clear_body" >/dev/null
opn_kea_reconfigure
pass "Core DDNS disabled and subnet fields cleared (clean state)"
