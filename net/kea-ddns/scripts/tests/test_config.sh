# Test: configuration validation (sections 1-5)
# Validates core patches, JSON configs, keactrl, DHCP4 params, and DDNS zones.

# --- 1. Core patch applied ---
if grep -q 'kea_ddns_generate' "$KEA_INC" 2>/dev/null; then
    pass "Core patch: kea.inc contains plugin hooks"
else
    fail "Core patch: kea.inc missing kea_ddns_generate hook"
fi

if grep -q 'kea_dhcpv4_config' "$KEA_DHCPV4_PHP" 2>/dev/null; then
    pass "Core patch: KeaDhcpv4.php contains plugin hooks"
else
    fail "Core patch: KeaDhcpv4.php missing kea_dhcpv4_config hook"
fi

if grep -q 'kea_dhcpv6_config' "$KEA_DHCPV6_PHP" 2>/dev/null; then
    pass "Core patch: KeaDhcpv6.php contains plugin hooks"
else
    fail "Core patch: KeaDhcpv6.php missing kea_dhcpv6_config hook"
fi

# --- 2. Config files valid JSON ---
if jq . < "$DDNS_CONF" >/dev/null 2>&1; then
    pass "Config: kea-dhcp-ddns.conf is valid JSON"
else
    fail "Config: kea-dhcp-ddns.conf is not valid JSON"
fi

if jq . < "$KEA4_CONF" >/dev/null 2>&1; then
    pass "Config: kea-dhcp4.conf is valid JSON"
else
    fail "Config: kea-dhcp4.conf is not valid JSON"
fi

# --- 3. keactrl has dhcp_ddns enabled ---
if grep -q 'dhcp_ddns=yes' "$KEACTRL_CONF" 2>/dev/null; then
    pass "keactrl: dhcp_ddns=yes"
else
    fail "keactrl: dhcp_ddns not enabled in keactrl.conf"
fi

# --- 4. DDNS parameters in kea-dhcp4.conf ---
DDNS_ENABLED=$(jq -r '.Dhcp4["dhcp-ddns"]["enable-updates"]' < "$KEA4_CONF" 2>/dev/null)
if [ "$DDNS_ENABLED" = "true" ]; then
    pass "kea-dhcp4: dhcp-ddns.enable-updates is true"
else
    fail "kea-dhcp4: dhcp-ddns.enable-updates is not true (got: $DDNS_ENABLED)"
fi

HOSTNAME_CHARSET=$(jq -r '.Dhcp4["hostname-char-set"]' < "$KEA4_CONF" 2>/dev/null)
if [ -n "$HOSTNAME_CHARSET" ] && [ "$HOSTNAME_CHARSET" != "null" ]; then
    pass "kea-dhcp4: hostname-char-set is set ($HOSTNAME_CHARSET)"
else
    fail "kea-dhcp4: hostname-char-set is not set"
fi

DDNS_SUBNET_COUNT=$(jq '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)] | length' < "$KEA4_CONF" 2>/dev/null)
if [ "$DDNS_SUBNET_COUNT" -gt 0 ] 2>/dev/null; then
    pass "kea-dhcp4: $DDNS_SUBNET_COUNT subnet(s) with ddns-send-updates enabled"
else
    fail "kea-dhcp4: no subnets with ddns-send-updates enabled"
fi

# --- 4b. DDNS parameters in kea-dhcp6.conf (if DHCPv6 enabled) ---
KEA6_VALID=false
if [ -f "$KEA6_CONF" ] && jq . < "$KEA6_CONF" >/dev/null 2>&1; then
    KEA6_VALID=true
    pass "Config: kea-dhcp6.conf is valid JSON"

    DDNS6_ENABLED=$(jq -r '.Dhcp6["dhcp-ddns"]["enable-updates"]' < "$KEA6_CONF" 2>/dev/null)
    if [ "$DDNS6_ENABLED" = "true" ]; then
        pass "kea-dhcp6: dhcp-ddns.enable-updates is true"
    else
        pass "kea-dhcp6: dhcp-ddns.enable-updates is $DDNS6_ENABLED (no v6 DDNS assignments)"
    fi

    DDNS6_SUBNET_COUNT=$(jq '[.Dhcp6.subnet6[] | select(.["ddns-send-updates"] == true)] | length' < "$KEA6_CONF" 2>/dev/null)
    if [ "$DDNS6_SUBNET_COUNT" -gt 0 ] 2>/dev/null; then
        pass "kea-dhcp6: $DDNS6_SUBNET_COUNT subnet6(s) with ddns-send-updates enabled"
    else
        pass "kea-dhcp6: no subnet6 DDNS assignments yet (will test after configuration)"
    fi
fi

# --- 5. kea-dhcp-ddns.conf has zones ---
FWD_COUNT=$(jq '.DhcpDdns["forward-ddns"]["ddns-domains"] | length' < "$DDNS_CONF" 2>/dev/null)
if [ "$FWD_COUNT" -gt 0 ] 2>/dev/null; then
    pass "kea-dhcp-ddns: $FWD_COUNT forward zone(s) configured"
else
    fail "kea-dhcp-ddns: no forward zones configured"
fi

REV_COUNT=$(jq '.DhcpDdns["reverse-ddns"]["ddns-domains"] | length' < "$DDNS_CONF" 2>/dev/null)
if [ "$REV_COUNT" -gt 0 ] 2>/dev/null; then
    pass "kea-dhcp-ddns: $REV_COUNT reverse zone(s) configured"
else
    fail "kea-dhcp-ddns: no reverse zones configured"
fi

TSIG_COUNT=$(jq '.DhcpDdns["tsig-keys"] | length' < "$DDNS_CONF" 2>/dev/null)
if [ "$TSIG_COUNT" -gt 0 ] 2>/dev/null; then
    pass "kea-dhcp-ddns: $TSIG_COUNT TSIG key(s) configured"
else
    fail "kea-dhcp-ddns: no TSIG keys configured"
fi
