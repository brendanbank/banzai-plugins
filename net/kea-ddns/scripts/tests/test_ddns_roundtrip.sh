# Test: DDNS round-trip (section 11)
# Adds synthetic leases, triggers DDNS, verifies DNS, then cleans up.

# Extract TSIG key for DNS cleanup (shared between v4 and v6)
TSIG_NAME=$(jq -r '.DhcpDdns["tsig-keys"][0].name' < "$DDNS_CONF" 2>/dev/null)
TSIG_ALGO=$(jq -r '.DhcpDdns["tsig-keys"][0].algorithm' < "$DDNS_CONF" 2>/dev/null)
TSIG_SECRET=$(jq -r '.DhcpDdns["tsig-keys"][0].secret' < "$DDNS_CONF" 2>/dev/null)

# --- 11a. DDNS round-trip: DHCPv4 ---
TEST_MAC="de:ad:be:ef:00:01"

# Pick the first DDNS-enabled subnet and derive a test IP from it
TEST_SUBNET_ID=$(jq -r '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)][0].id' < "$KEA4_CONF" 2>/dev/null)
TEST_SUFFIX=$(jq -r '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)][0]["ddns-qualifying-suffix"]' < "$KEA4_CONF" 2>/dev/null)
TEST_CIDR=$(jq -r '[.Dhcp4.subnet4[] | select(.["ddns-send-updates"] == true)][0].subnet' < "$KEA4_CONF" 2>/dev/null)

# Derive test IP: use .254 in the first /24-aligned block of the subnet
TEST_NET=$(echo "$TEST_CIDR" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
TEST_IP="${TEST_NET}.254"
TEST_SUFFIX="${TEST_SUFFIX%.}"
TEST_HOSTNAME="keaddns-functest.${TEST_SUFFIX}"

FWD_ZONE=$(jq -r --arg suffix "${TEST_SUFFIX}." '.DhcpDdns["forward-ddns"]["ddns-domains"][] | select(.name == $suffix) | .name' < "$DDNS_CONF" 2>/dev/null)
# Derive reverse zone from test IP: 10.0.10.254 -> 10.0.10.in-addr.arpa.
REV_ZONE=$(echo "$TEST_IP" | awk -F. '{print $3"."$2"."$1".in-addr.arpa."}')

# Build the reverse name: 10.0.10.254 -> 254.10.0.10.in-addr.arpa
TEST_PTR=$(echo "$TEST_IP" | awk -F. '{print $4"."$3"."$2"."$1}').in-addr.arpa

ddns_cleanup() {
    # Delete the test lease (ignore errors)
    kea_command "$KEA4_SOCK" "{\"command\": \"lease4-del\", \"arguments\": {\"ip-address\": \"$TEST_IP\"}}" >/dev/null 2>&1
    # Remove DNS records via nsupdate
    nsupdate -y "${TSIG_ALGO}:${TSIG_NAME}:${TSIG_SECRET}" << EOF 2>/dev/null
server ${DNS_SERVER}
zone ${FWD_ZONE}
update delete ${TEST_HOSTNAME} A
send
EOF
    nsupdate -y "${TSIG_ALGO}:${TSIG_NAME}:${TSIG_SECRET}" << EOF 2>/dev/null
server ${DNS_SERVER}
zone ${REV_ZONE}
update delete ${TEST_PTR} PTR
send
EOF
}

if [ -n "$TEST_SUBNET_ID" ] && [ "$TEST_SUBNET_ID" != "null" ]; then
    # Clean up any stale test records from a previous run
    ddns_cleanup

    # Add test lease
    ADD_RESULT=$(kea_command "$KEA4_SOCK" "{\"command\": \"lease4-add\", \"arguments\": {\"ip-address\": \"$TEST_IP\", \"hw-address\": \"$TEST_MAC\", \"hostname\": \"$TEST_HOSTNAME\", \"fqdn-fwd\": true, \"fqdn-rev\": true, \"subnet-id\": $TEST_SUBNET_ID}}")
    if echo "$ADD_RESULT" | jq -e '.result == 0' >/dev/null 2>&1; then
        pass "DDNS round-trip: test lease added ($TEST_HOSTNAME -> $TEST_IP)"

        # Trigger DDNS
        RESEND_RESULT=$(kea_command "$KEA4_SOCK" "{\"command\": \"lease4-resend-ddns\", \"arguments\": {\"ip-address\": \"$TEST_IP\"}}")
        if echo "$RESEND_RESULT" | jq -e '.result == 0' >/dev/null 2>&1; then
            pass "DDNS round-trip: NCR generated"
        else
            fail "DDNS round-trip: lease4-resend-ddns failed"
        fi

        # Wait for DDNS propagation
        sleep 3

        # Check forward DNS
        RESOLVED_IP=$(dig +short "$TEST_HOSTNAME" "@$DNS_SERVER" 2>/dev/null | head -1)
        if [ "$RESOLVED_IP" = "$TEST_IP" ]; then
            pass "DDNS round-trip: forward DNS $TEST_HOSTNAME -> $TEST_IP"
        else
            fail "DDNS round-trip: forward DNS expected $TEST_IP, got ${RESOLVED_IP:-NXDOMAIN}"
        fi

        # Check reverse DNS
        RESOLVED_NAME=$(dig +short -x "$TEST_IP" "@$DNS_SERVER" 2>/dev/null | head -1)
        EXPECTED_NAME="${TEST_HOSTNAME%.}."
        if [ "$RESOLVED_NAME" = "$EXPECTED_NAME" ]; then
            pass "DDNS round-trip: reverse DNS $TEST_IP -> $TEST_HOSTNAME"
        else
            fail "DDNS round-trip: reverse DNS expected $TEST_HOSTNAME, got ${RESOLVED_NAME:-NXDOMAIN}"
        fi

        # Clean up
        ddns_cleanup
    else
        fail "DDNS round-trip: failed to add test lease"
    fi
else
    fail "DDNS round-trip: no DDNS-enabled subnet found for $TEST_IP"
fi

# --- 11b. DDNS round-trip: DHCPv6 ---
if [ "$KEA6_VALID" = "true" ]; then
    TEST6_DUID="de:ad:be:ef:ca:fe:00:06"
    TEST6_IAID=1

    TEST6_SUBNET_ID=$(jq -r '[.Dhcp6.subnet6[] | select(.["ddns-send-updates"] == true)][0].id' < "$KEA6_CONF" 2>/dev/null)
    TEST6_SUFFIX=$(jq -r '[.Dhcp6.subnet6[] | select(.["ddns-send-updates"] == true)][0]["ddns-qualifying-suffix"]' < "$KEA6_CONF" 2>/dev/null)
    TEST6_CIDR=$(jq -r '[.Dhcp6.subnet6[] | select(.["ddns-send-updates"] == true)][0].subnet' < "$KEA6_CONF" 2>/dev/null)

    if [ -n "$TEST6_SUBNET_ID" ] && [ "$TEST6_SUBNET_ID" != "null" ]; then
        TEST6_SUFFIX="${TEST6_SUFFIX%.}"

        if [ -z "$TEST6_SUFFIX" ] || [ "$TEST6_SUFFIX" = "null" ]; then
            pass "DDNS v6 round-trip: no qualifying suffix configured (skipped)"
        else
            # Derive test IPv6 address: strip trailing :: from prefix, append ::fffe
            TEST6_PREFIX=$(echo "$TEST6_CIDR" | cut -d/ -f1 | sed 's/::$//')
            TEST6_IP="${TEST6_PREFIX}::fffe"
            TEST6_HOSTNAME="keaddns-functest6.${TEST6_SUFFIX}"

            # Forward zone for cleanup
            TEST6_FWD_ZONE=$(jq -r --arg suffix "${TEST6_SUFFIX}." '.DhcpDdns["forward-ddns"]["ddns-domains"][] | select(.name == $suffix) | .name' < "$DDNS_CONF" 2>/dev/null)

            # Build ip6.arpa PTR name for cleanup (requires python3)
            TEST6_PTR=""
            if command -v python3 >/dev/null 2>&1; then
                TEST6_PTR=$(python3 -c "import ipaddress; print(ipaddress.ip_address('$TEST6_IP').reverse_pointer)" 2>/dev/null)
            fi
            REV6_ZONE=$(jq -r '.DhcpDdns["reverse-ddns"]["ddns-domains"][] | select(.name | test("ip6\\.arpa")) | .name' < "$DDNS_CONF" 2>/dev/null | head -1)

            ddns6_cleanup() {
                kea_command "$KEA6_SOCK" "{\"command\": \"lease6-del\", \"arguments\": {\"ip-address\": \"$TEST6_IP\"}}" >/dev/null 2>&1
                if [ -n "$TEST6_FWD_ZONE" ]; then
                    nsupdate -y "${TSIG_ALGO}:${TSIG_NAME}:${TSIG_SECRET}" << EOF 2>/dev/null
server ${DNS_SERVER}
zone ${TEST6_FWD_ZONE}
update delete ${TEST6_HOSTNAME} AAAA
send
EOF
                fi
                if [ -n "$TEST6_PTR" ] && [ -n "$REV6_ZONE" ]; then
                    nsupdate -y "${TSIG_ALGO}:${TSIG_NAME}:${TSIG_SECRET}" << EOF 2>/dev/null
server ${DNS_SERVER}
zone ${REV6_ZONE}
update delete ${TEST6_PTR} PTR
send
EOF
                fi
            }

            # Clean stale records from previous run
            ddns6_cleanup

            # Add test v6 lease
            ADD6_RESULT=$(kea_command "$KEA6_SOCK" "{\"command\": \"lease6-add\", \"arguments\": {\"ip-address\": \"$TEST6_IP\", \"duid\": \"$TEST6_DUID\", \"iaid\": $TEST6_IAID, \"hostname\": \"$TEST6_HOSTNAME\", \"fqdn-fwd\": true, \"fqdn-rev\": true, \"subnet-id\": $TEST6_SUBNET_ID}}")
            if echo "$ADD6_RESULT" | jq -e '.result == 0' >/dev/null 2>&1; then
                pass "DDNS v6 round-trip: test lease added ($TEST6_HOSTNAME -> $TEST6_IP)"

                RESEND6_RESULT=$(kea_command "$KEA6_SOCK" "{\"command\": \"lease6-resend-ddns\", \"arguments\": {\"ip-address\": \"$TEST6_IP\"}}")
                if echo "$RESEND6_RESULT" | jq -e '.result == 0' >/dev/null 2>&1; then
                    pass "DDNS v6 round-trip: NCR generated"
                else
                    fail "DDNS v6 round-trip: lease6-resend-ddns failed"
                fi

                sleep 3

                # Check forward AAAA
                RESOLVED6_IP=$(dig +short AAAA "$TEST6_HOSTNAME" "@$DNS_SERVER" 2>/dev/null | head -1)
                if [ "$RESOLVED6_IP" = "$TEST6_IP" ]; then
                    pass "DDNS v6 round-trip: forward DNS $TEST6_HOSTNAME -> $TEST6_IP (AAAA)"
                else
                    fail "DDNS v6 round-trip: forward DNS expected $TEST6_IP, got ${RESOLVED6_IP:-NXDOMAIN}"
                fi

                # Check reverse PTR (ip6.arpa)
                RESOLVED6_NAME=$(dig +short -x "$TEST6_IP" "@$DNS_SERVER" 2>/dev/null | head -1)
                EXPECTED6_NAME="${TEST6_HOSTNAME%.}."
                if [ "$RESOLVED6_NAME" = "$EXPECTED6_NAME" ]; then
                    pass "DDNS v6 round-trip: reverse DNS $TEST6_IP -> $TEST6_HOSTNAME (ip6.arpa PTR)"
                else
                    fail "DDNS v6 round-trip: reverse DNS expected $TEST6_HOSTNAME, got ${RESOLVED6_NAME:-NXDOMAIN}"
                fi

                ddns6_cleanup
            else
                fail "DDNS v6 round-trip: failed to add test lease"
            fi
        fi
    else
        pass "DDNS v6 round-trip: no DDNS-enabled v6 subnet (skipped)"
    fi
fi
