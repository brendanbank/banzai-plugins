# Shared library for kea-ddns functional tests
# Source this file; do not execute directly.

KEA_DIR="/usr/local/etc/kea"
KEA_INC="/usr/local/etc/inc/plugins.inc.d/kea.inc"
KEA_DHCPV4_PHP="/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php"
KEA_DHCPV6_PHP="/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php"
KEA4_CONF="$KEA_DIR/kea-dhcp4.conf"
KEA6_CONF="$KEA_DIR/kea-dhcp6.conf"
DDNS_CONF="$KEA_DIR/kea-dhcp-ddns.conf"
KEACTRL_CONF="$KEA_DIR/keactrl.conf"
KEA4_SOCK="/var/run/kea/kea4-ctrl-socket"
KEA6_SOCK="/var/run/kea/kea6-ctrl-socket"
DDNS_SOCK="/var/run/kea/kea-ddns-ctrl-socket"

RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

pass() {
    echo "P" >> "$RESULTS_FILE"
    printf "${GREEN}[PASS]${RESET} %s\n" "$1"
}

fail() {
    echo "F" >> "$RESULTS_FILE"
    printf "${RED}[FAIL]${RESET} %s\n" "$1"
}

kea_command() {
    _sock="$1"
    _cmd="$2"
    echo "$_cmd" | socat UNIX-CONNECT:"$_sock" - 2>/dev/null
}

# DNS server extracted from DDNS config (set after preflight)
DNS_SERVER=""

# --- Preflight ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root"
    exit 1
fi

for cmd in jq socat dig pgrep nsupdate; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
done

# Resolve DNS server from config
DNS_SERVER=$(jq -r '.DhcpDdns["forward-ddns"]["ddns-domains"][0]["dns-servers"][0]["ip-address"]' < "$DDNS_CONF" 2>/dev/null)
if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER="127.0.0.1"
fi
