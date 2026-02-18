#!/usr/bin/env python3
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
# Requires: gpg-agent (gpg-connect-agent)
# Optional: GPG_SIGN_KEYGRIP (override signing key keygrip)
#           REPO_PUB (path to public key PEM file)
#
# Copyright (c) 2025 Brendan Bank
# SPDX-License-Identifier: BSD-2-Clause
#

import hashlib
import os
import re
import subprocess
import sys

# Default keygrip of the GPG signing subkey (F60F2EAA7F5ACC52) on the YubiKey
DEFAULT_KEYGRIP = "18F8114597D68C3AC976ADC0B7044E387EEB9B5F"


def find_repo_pub():
    """Locate the public key PEM file."""
    # Environment variable override
    env_path = os.environ.get("REPO_PUB")
    if env_path:
        return env_path

    # Same directory as this script (when scp'd alongside repo.pub)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(script_dir, "repo.pub")
    if os.path.isfile(path):
        return path

    # Keys/ relative to repo root (when running locally)
    repo_root = os.path.dirname(script_dir)
    path = os.path.join(repo_root, "Keys", "repo.pub")
    if os.path.isfile(path):
        return path

    return None


def decode_assuan_data(stdout):
    """Decode Assuan protocol D lines (%-encoded binary) and concatenate."""
    data_parts = []
    for line in stdout.split(b"\n"):
        if not line.startswith(b"D "):
            continue
        part = line[2:]
        decoded = b""
        i = 0
        while i < len(part):
            if part[i:i + 1] == b"%" and i + 2 < len(part):
                decoded += bytes([int(part[i + 1:i + 3], 16)])
                i += 3
            else:
                decoded += part[i:i + 1]
                i += 1
        data_parts.append(decoded)
    return b"".join(data_parts)


def extract_rsa_signature(sexp):
    """Extract the raw RSA signature bytes from a gpg-agent S-expression.

    The S-expression has the form: (7:sig-val(3:rsa(1:s<len>:<sig>)))
    """
    m = re.search(rb"\(1:s(\d+):", sexp)
    if not m:
        die("could not parse signature S-expression")

    sig_len = int(m.group(1))
    sig = sexp[m.end():m.end() + sig_len]
    if len(sig) != sig_len:
        die(f"expected {sig_len} byte signature, got {len(sig)}")

    return sig


def die(msg):
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(1)


def main():
    keygrip = os.environ.get("GPG_SIGN_KEYGRIP", DEFAULT_KEYGRIP)

    repo_pub = find_repo_pub()
    if not repo_pub or not os.path.isfile(repo_pub):
        die(f"public key not found (searched REPO_PUB, script dir, Keys/)")

    # pkg repo sends SHA256(data) as a hex string on stdin. It doesn't close
    # stdin, so read one line only. pkg verifies against SHA256(hex_string),
    # so hash it again.
    hex_hash = sys.stdin.readline().strip()
    if not hex_hash:
        die("no hash received on stdin")

    double_hash = hashlib.sha256(hex_hash.encode()).hexdigest().upper()

    # Sign via gpg-agent: SIGKEY selects the key, SETHASH sets the digest,
    # PKSIGN produces the signature. PIN prompting goes through pinentry.
    result = subprocess.run(
        ["gpg-connect-agent",
         f"SIGKEY {keygrip}",
         f"SETHASH --hash=sha256 {double_hash}",
         "PKSIGN", "/bye"],
        capture_output=True,
    )

    if result.returncode != 0:
        die("gpg-connect-agent failed")

    sexp = decode_assuan_data(result.stdout)
    sig = extract_rsa_signature(sexp)

    # Output in the format pkg expects
    with open(repo_pub, "rb") as f:
        pub_pem = f.read()

    sys.stdout.buffer.write(b"SIGNATURE\n")
    sys.stdout.buffer.write(sig)
    sys.stdout.buffer.write(b"\nCERT\n")
    sys.stdout.buffer.write(pub_pem)
    sys.stdout.buffer.write(b"END\n")
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
