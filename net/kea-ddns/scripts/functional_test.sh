#!/bin/sh

# Functional test for opnsense-kea-ddns
# Validates the full DDNS pipeline: core patches, config files, running daemons,
# active leases, and DNS records.
#
# Usage: sudo sh scripts/functional_test.sh

# Resolve script directory (works when piped via ssh too)
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ ! -d "$SCRIPT_DIR/tests" ]; then
    SCRIPT_DIR="."
fi

. "$SCRIPT_DIR/tests/lib.sh"

echo "kea-ddns functional test"
echo "========================"
echo ""

. "$SCRIPT_DIR/tests/test_config.sh"
. "$SCRIPT_DIR/tests/test_runtime.sh"
# LEASES_JSON is now set by test_runtime.sh
. "$SCRIPT_DIR/tests/test_dns.sh"
. "$SCRIPT_DIR/tests/test_ddns_roundtrip.sh"

# --- Summary ---
echo ""
PASS_COUNT=$(grep -c '^P$' "$RESULTS_FILE" 2>/dev/null) || PASS_COUNT=0
FAIL_COUNT=$(grep -c '^F$' "$RESULTS_FILE" 2>/dev/null) || FAIL_COUNT=0
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Results: $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
