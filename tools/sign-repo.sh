#!/bin/sh
#
# Sign pkg repo data for FreeBSD pkg repo signing_command.
# Reads data from stdin (what pkg repo pipes), signs with YubiKey PIV,
# and outputs the format pkg expects: SIGNATURE, binary sig, CERT, PEM, END.
#
# The private key stays on the YubiKey; only this host needs the YubiKey
# and the public key (Keys/repo.pub must match the key in the slot).
#
# Requires: yubico-piv-tool (e.g. brew install yubico-piv-tool)
# Optional: PIV_PIN, YUBICO_PIV_SLOT (default 9c), YUBICO_PIV_ALG (default RSA2048; use RSA4096 for 4096-bit keys)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_PUB="${REPO_ROOT}/Keys/repo.pub"
SLOT="${YUBICO_PIV_SLOT:-9c}"
ALG="${YUBICO_PIV_ALG:-RSA2048}"

[ -f "${REPO_PUB}" ] || { echo "ERROR: ${REPO_PUB} not found" >&2; exit 1; }

INPUT=$(mktemp)
SIG=$(mktemp)
trap 'rm -f "${INPUT}" "${SIG}"' EXIT

cat > "${INPUT}"

if ! command -v yubico-piv-tool >/dev/null 2>&1; then
    echo "ERROR: yubico-piv-tool not found (e.g. brew install yubico-piv-tool)" >&2
    exit 1
fi

# PIV slot 9c = Digital Signature; hashes input with SHA256 and signs
if [ -n "${PIV_PIN}" ]; then
    yubico-piv-tool -a verify-pin -a sign -s "${SLOT}" -H SHA256 -A "${ALG}" \
        -P "${PIV_PIN}" -i "${INPUT}" -o "${SIG}" 2>/dev/null
else
    yubico-piv-tool -a verify-pin -a sign -s "${SLOT}" -H SHA256 -A "${ALG}" \
        -i "${INPUT}" -o "${SIG}" 2>/dev/null
fi || {
    echo "ERROR: YubiKey signing failed (check slot ${SLOT}, PIN, and YUBICO_PIV_ALG=${ALG})" >&2
    exit 1
}

echo "SIGNATURE"
cat "${SIG}"
echo ""
echo "CERT"
cat "${REPO_PUB}"
echo "END"
