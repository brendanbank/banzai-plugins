#!/bin/sh
#
# Sign pkg repo data for FreeBSD pkg repo signing_command.
# Reads a SHA256 hex hash from stdin (what pkg repo pipes), signs it with
# the GPG signing subkey on the YubiKey via gpg-agent, and outputs the
# format pkg expects: SIGNATURE, binary sig, CERT, PEM public key, END.
#
# pkg sends SHA256(data) as a hex string, and verifies the signature against
# SHA256(hex_string) — so we hash the hex string again before signing.
#
# The private key stays on the YubiKey. PIN entry goes through pinentry
# (e.g. pinentry-mac), so no PIV_PIN variable or /dev/tty hacks are needed.
#
# Requires: gpg-agent, python3, openssl
# Optional: GPG_SIGN_KEYGRIP (override signing key keygrip)
#           REPO_PUB (path to public key PEM file)
#
# Copyright (c) 2025 Brendan Bank
# SPDX-License-Identifier: BSD-2-Clause
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PUB="${REPO_PUB:-${SCRIPT_DIR}/repo.pub}"
if [ ! -f "${REPO_PUB}" ]; then
    # Fall back to Keys/ relative to repo root (when running locally)
    REPO_PUB="$(cd "${SCRIPT_DIR}/.." && pwd)/Keys/repo.pub"
fi

# Keygrip of the GPG signing subkey (F60F2EAA7F5ACC52) on the YubiKey
KEYGRIP="${GPG_SIGN_KEYGRIP:-18F8114597D68C3AC976ADC0B7044E387EEB9B5F}"

[ -f "${REPO_PUB}" ] || { echo "ERROR: ${REPO_PUB} not found" >&2; exit 1; }

for cmd in gpg-connect-agent python3 openssl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd not found" >&2; exit 1
    }
done

SIG=$(mktemp)
trap 'rm -f "${SIG}"' EXIT

# pkg repo sends SHA256(data) as a hex string on stdin (doesn't close stdin,
# so use read). pkg verifies against SHA256(hex_string), so hash it again.
read -r HEX_HASH
HASH=$(printf '%s' "${HEX_HASH}" | openssl dgst -sha256 -hex 2>/dev/null \
    | awk '{print $NF}' | tr 'a-f' 'A-F')

# Sign via gpg-agent PKSIGN and extract raw RSA signature from S-expression.
# gpg-agent handles PIN prompting through pinentry (GUI or curses).
python3 -c '
import subprocess, re, sys

keygrip = sys.argv[1]
hash_hex = sys.argv[2]
output_file = sys.argv[3]

result = subprocess.run(
    ["gpg-connect-agent",
     "SIGKEY " + keygrip,
     "SETHASH --hash=sha256 " + hash_hex,
     "PKSIGN", "/bye"],
    capture_output=True
)

if result.returncode != 0:
    sys.stderr.write("ERROR: gpg-connect-agent failed\n")
    sys.exit(1)

# Decode Assuan protocol D lines (%-encoded binary)
data_parts = []
for line in result.stdout.split(b"\n"):
    if line.startswith(b"D "):
        part = line[2:]
        decoded = b""
        i = 0
        while i < len(part):
            if part[i:i+1] == b"%" and i + 2 < len(part):
                decoded += bytes([int(part[i+1:i+3], 16)])
                i += 3
            else:
                decoded += part[i:i+1]
                i += 1
        data_parts.append(decoded)

sexp = b"".join(data_parts)

# Parse raw RSA signature from S-expression: (7:sig-val(3:rsa(1:s<len>:<sig>)))
m = re.search(rb"\(1:s(\d+):", sexp)
if not m:
    sys.stderr.write("ERROR: could not parse signature S-expression\n")
    sys.exit(1)

sig_len = int(m.group(1))
sig = sexp[m.end():m.end() + sig_len]
if len(sig) != sig_len:
    sys.stderr.write(f"ERROR: expected {sig_len} byte signature, got {len(sig)}\n")
    sys.exit(1)

with open(output_file, "wb") as f:
    f.write(sig)
' "${KEYGRIP}" "${HASH}" "${SIG}" || {
    echo "ERROR: GPG signing failed" >&2
    exit 1
}

echo "SIGNATURE"
cat "${SIG}"
echo ""
echo "CERT"
cat "${REPO_PUB}"
echo "END"
