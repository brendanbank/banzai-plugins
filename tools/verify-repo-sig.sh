#!/bin/sh
#
# Verify pkg repo signatures against the public key.
#
# Extracts signatures from packagesite.pkg and data.pkg, then verifies
# each against the double-hash (SHA256(SHA256_hex(content))) that pkg
# uses internally.
#
# Usage: ./tools/verify-repo-sig.sh [repo-dir]
#        Default repo-dir: docs/FreeBSD:14:amd64/26.1/repo
#
# Copyright (c) 2025 Brendan Bank
# SPDX-License-Identifier: BSD-2-Clause
#

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="${1:-${REPO_ROOT}/docs/FreeBSD:14:amd64/26.1/repo}"
PUBKEY="${REPO_ROOT}/Keys/repo.pub"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }

verify_archive() {
    archive="$1"
    name=$(basename "${archive}" .pkg)

    [ -f "${archive}" ] || die "${archive} not found"

    workdir="${TMPDIR}/${name}"
    mkdir -p "${workdir}"
    tar xf "${archive}" -C "${workdir}" 2>/dev/null

    # Find the content, sig, and pub files (name varies: data vs packagesite.yaml)
    sig=$(ls "${workdir}"/*.sig 2>/dev/null | head -1)
    pub=$(ls "${workdir}"/*.pub 2>/dev/null | head -1)
    content=$(ls "${workdir}"/* 2>/dev/null | grep -v '\.sig$' | grep -v '\.pub$' | head -1)

    [ -n "${sig}" ] || die "${name}: no .sig file found"
    [ -n "${pub}" ] || die "${name}: no .pub file found"
    [ -n "${content}" ] || die "${name}: no content file found"

    # Check embedded pubkey matches repo key
    if ! diff -q "${pub}" "${PUBKEY}" >/dev/null 2>&1; then
        echo "FAIL: ${name}: embedded public key does not match Keys/repo.pub"
        FAIL=$((FAIL + 1))
        return
    fi

    # Recover digest from signature
    recovered="${workdir}/recovered.bin"
    if ! openssl pkeyutl -verifyrecover -pubin -inkey "${pub}" -in "${sig}" -out "${recovered}" 2>/dev/null; then
        # Fall back to rsautl for older openssl
        if ! openssl rsautl -verify -pubin -inkey "${pub}" -in "${sig}" -out "${recovered}" 2>/dev/null; then
            echo "FAIL: ${name}: could not recover digest from signature"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    # Compute expected double hash: SHA256(SHA256_hex(content))
    content_hash_hex=$(shasum -a 256 "${content}" | awk '{print $1}')
    double_hash=$(printf '%s' "${content_hash_hex}" | shasum -a 256 | awk '{print $1}')

    # Extract hash from recovered DigestInfo (last 32 bytes = 64 hex chars)
    recovered_hex=$(xxd -p "${recovered}" | tr -d '\n')
    recovered_hash=$(echo "${recovered_hex}" | tail -c 65)

    if [ "${recovered_hash}" = "${double_hash}" ]; then
        echo "OK:   ${name}: signature valid"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name}: signature mismatch"
        echo "      expected: ${double_hash}"
        echo "      got:      ${recovered_hash}"
        FAIL=$((FAIL + 1))
    fi
}

# Check fingerprint
echo "Repo: ${REPO_DIR}"
echo "Key:  ${PUBKEY}"
expected_fp=$(shasum -a 256 "${PUBKEY}" | awk '{print $1}')
stored_fp=$(grep '^fingerprint:' "${REPO_ROOT}/Keys/fingerprint" | awk '{print $2}')
if [ "${expected_fp}" = "${stored_fp}" ]; then
    echo "OK:   fingerprint matches Keys/fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL: fingerprint mismatch"
    echo "      computed: ${expected_fp}"
    echo "      stored:   ${stored_fp}"
    FAIL=$((FAIL + 1))
fi

# Verify each signed archive
verify_archive "${REPO_DIR}/packagesite.pkg"
verify_archive "${REPO_DIR}/data.pkg"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
