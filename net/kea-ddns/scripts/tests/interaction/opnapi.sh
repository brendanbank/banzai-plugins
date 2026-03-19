# opnapi.sh — OPNsense API helper functions
# Source this file; do not execute directly.

# Requires: OPN_HOST, OPN_API_KEY, OPN_API_SECRET

# Colors
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

# Test result tracking
RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

pass() {
    echo "P" >> "$RESULTS_FILE"
    printf "${GREEN}[PASS]${RESET} %s\n" "$1"
}

fail() {
    echo "F" >> "$RESULTS_FILE"
    printf "${RED}[FAIL]${RESET} %s\n" "$1"
}

skip() {
    echo "S" >> "$RESULTS_FILE"
    printf "${YELLOW}[SKIP]${RESET} %s\n" "$1"
}

info() {
    printf "${CYAN}[INFO]${RESET} %s\n" "$1"
}

section() {
    echo ""
    printf "${BOLD}── %s ──${RESET}\n" "$1"
}

results_summary() {
    echo ""
    PASS_COUNT=$(grep -c '^P$' "$RESULTS_FILE" 2>/dev/null) || PASS_COUNT=0
    FAIL_COUNT=$(grep -c '^F$' "$RESULTS_FILE" 2>/dev/null) || FAIL_COUNT=0
    SKIP_COUNT=$(grep -c '^S$' "$RESULTS_FILE" 2>/dev/null) || SKIP_COUNT=0
    TOTAL=$((PASS_COUNT + FAIL_COUNT))
    printf "${BOLD}Results: %d/%d passed, %d failed, %d skipped${RESET}\n" \
        "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT" "$SKIP_COUNT"
    [ "$FAIL_COUNT" -gt 0 ] && return 1
    return 0
}

# API call: opn_api METHOD /api/path [json_body]
# Returns the response body on stdout; writes HTTP code to /tmp/.opnapi_code
opn_api() {
    _method="$1"
    _path="$2"
    _body="${3:-}"

    _url="https://${OPN_HOST}${_path}"

    if [ -n "$_body" ]; then
        _response=$(curl -sS -k --max-time 30 \
            -u "${OPN_API_KEY}:${OPN_API_SECRET}" \
            -o /tmp/.opnapi_body -w '%{http_code}' \
            -X "$_method" \
            -H "Content-Type: application/json" \
            -d "$_body" "$_url" 2>/dev/null)
    else
        _response=$(curl -sS -k --max-time 30 \
            -u "${OPN_API_KEY}:${OPN_API_SECRET}" \
            -o /tmp/.opnapi_body -w '%{http_code}' \
            -X "$_method" "$_url" 2>/dev/null)
    fi

    echo "$_response" > /tmp/.opnapi_code
    cat /tmp/.opnapi_body 2>/dev/null
}

# GET helper
opn_get() {
    opn_api GET "$1"
}

# POST helper with JSON body
opn_post() {
    opn_api POST "$1" "$2"
}

# Read HTTP status code from last API call.
# Call this AFTER capturing output: _result=$(opn_get ...); _http_code
_http_code() {
    HTTP_CODE=$(cat /tmp/.opnapi_code 2>/dev/null)
}

# Remote command execution via SSH.
# Uses OPN_SSH_USER (default: root). Non-root users get sudo.
opn_ssh() {
    _ssh_user="${OPN_SSH_USER:-root}"
    if [ "$_ssh_user" = "root" ]; then
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${_ssh_user}@${OPN_HOST}" "$@" 2>/dev/null
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${_ssh_user}@${OPN_HOST}" "sudo $*" 2>/dev/null
    fi
}

# Read a remote file via SSH
opn_cat() {
    opn_ssh "cat '$1'" 2>/dev/null
}

# Check if a remote file exists
opn_file_exists() {
    opn_ssh "test -f '$1'" 2>/dev/null
}

# Check if a remote process is running
opn_pgrep() {
    opn_ssh "pgrep -x '$1'" >/dev/null 2>&1
}

# Run configctl on the firewall
opn_configctl() {
    opn_ssh "configctl $*"
}

# Run pluginctl on the firewall
opn_pluginctl() {
    opn_ssh "pluginctl $*"
}

# Reconfigure Kea via API and wait for it to settle
opn_kea_reconfigure() {
    info "Reconfiguring Kea services..."
    _result=$(opn_post "/api/kea/service/reconfigure" "{}"); _http_code
    _status=$(echo "$_result" | jq -r '.status // .result // empty' 2>/dev/null)
    if [ "$_status" = "ok" ] || [ "$HTTP_CODE" = "200" ]; then
        # Give services time to restart
        sleep 3
        return 0
    else
        echo "Reconfigure failed: $_result" >&2
        return 1
    fi
}

# Find a DHCPv4 subnet UUID by matching its subnet field
# Usage: find_subnet_uuid "10.99.99"
find_subnet_uuid() {
    _pattern="$1"
    _subnets=$(opn_get "/api/kea/dhcpv4/searchSubnet")
    echo "$_subnets" | jq -r \
        --arg pat "$_pattern" \
        '.rows[] | select(.subnet | contains($pat)) | .uuid' \
        2>/dev/null | head -1
}

# Load API credentials from key file (key:secret format)
load_api_key() {
    _keyfile="$1"
    # Expand ~ in path
    _keyfile=$(eval echo "$_keyfile")

    if [ ! -f "$_keyfile" ]; then
        echo "ERROR: API key file not found: $_keyfile" >&2
        exit 1
    fi

    OPN_API_KEY=$(head -1 "$_keyfile" | cut -d: -f1 | tr -d '[:space:]')
    OPN_API_SECRET=$(head -1 "$_keyfile" | cut -d: -f2- | tr -d '[:space:]')

    if [ -z "$OPN_API_KEY" ] || [ -z "$OPN_API_SECRET" ]; then
        echo "ERROR: Invalid API key format in $_keyfile (expected key:secret)" >&2
        exit 1
    fi
}
