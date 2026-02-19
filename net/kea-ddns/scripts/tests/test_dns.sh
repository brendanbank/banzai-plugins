# Test: DNS lookups (sections 9-10)
# Validates forward and reverse DNS for existing leases.
# Expects LEASES_JSON to be set (populated by test_runtime.sh).

# --- 9. DNS forward lookups ---
FWD_SAMPLE=$(echo "$LEASES_JSON" | jq -r '[.arguments.leases[] | select(.["fqdn-fwd"] == true)] | .[0:5][] | "\(.hostname) \(.["ip-address"])"' 2>/dev/null)

if [ -n "$FWD_SAMPLE" ]; then
    echo "$FWD_SAMPLE" | while IFS=' ' read -r hostname ip; do
        [ -z "$hostname" ] && continue
        RESOLVED=$(dig +short "$hostname" "@$DNS_SERVER" 2>/dev/null | head -1)
        if [ "$RESOLVED" = "$ip" ]; then
            pass "DNS forward: $hostname -> $ip"
        else
            fail "DNS forward: expected $ip for $hostname, got ${RESOLVED:-NXDOMAIN}"
        fi
    done
fi

# --- 10. DNS reverse lookups ---
REV_SAMPLE=$(echo "$LEASES_JSON" | jq -r '[.arguments.leases[] | select(.["fqdn-rev"] == true)] | .[0:5][] | "\(.hostname) \(.["ip-address"])"' 2>/dev/null)

if [ -n "$REV_SAMPLE" ]; then
    echo "$REV_SAMPLE" | while IFS=' ' read -r hostname ip; do
        [ -z "$ip" ] && continue
        RESOLVED=$(dig +short -x "$ip" "@$DNS_SERVER" 2>/dev/null | head -1)
        # dig returns trailing dot, normalize both
        EXPECTED="${hostname%.}."
        if [ "$RESOLVED" = "$EXPECTED" ]; then
            pass "DNS reverse: $ip -> $hostname"
        else
            fail "DNS reverse: expected $hostname for $ip, got ${RESOLVED:-NXDOMAIN}"
        fi
    done
fi

# --- 9b. DNS forward lookups for v6 leases (AAAA) ---
if [ "$KEA6_VALID" = "true" ] && [ -n "$LEASES6_JSON" ]; then
    FWD6_SAMPLE=$(echo "$LEASES6_JSON" | jq -r '[.arguments.leases[] | select(.["fqdn-fwd"] == true)] | .[0:5][] | "\(.hostname) \(.["ip-address"])"' 2>/dev/null)

    if [ -n "$FWD6_SAMPLE" ]; then
        echo "$FWD6_SAMPLE" | while IFS=' ' read -r hostname ip; do
            [ -z "$hostname" ] && continue
            RESOLVED=$(dig +short AAAA "$hostname" "@$DNS_SERVER" 2>/dev/null | head -1)
            if [ "$RESOLVED" = "$ip" ]; then
                pass "DNS forward v6: $hostname -> $ip (AAAA)"
            else
                fail "DNS forward v6: expected $ip for $hostname, got ${RESOLVED:-NXDOMAIN}"
            fi
        done
    fi

    # --- 10b. DNS reverse lookups for v6 leases (ip6.arpa PTR) ---
    REV6_SAMPLE=$(echo "$LEASES6_JSON" | jq -r '[.arguments.leases[] | select(.["fqdn-rev"] == true)] | .[0:5][] | "\(.hostname) \(.["ip-address"])"' 2>/dev/null)

    if [ -n "$REV6_SAMPLE" ]; then
        echo "$REV6_SAMPLE" | while IFS=' ' read -r hostname ip; do
            [ -z "$ip" ] && continue
            RESOLVED=$(dig +short -x "$ip" "@$DNS_SERVER" 2>/dev/null | head -1)
            EXPECTED="${hostname%.}."
            if [ "$RESOLVED" = "$EXPECTED" ]; then
                pass "DNS reverse v6: $ip -> $hostname (ip6.arpa PTR)"
            else
                fail "DNS reverse v6: expected $hostname for $ip, got ${RESOLVED:-NXDOMAIN}"
            fi
        done
    fi
fi
