#!/usr/bin/env python3

# Copyright (C) 2025 Brendan Bank
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

#
# Sign pkg repo data for FreeBSD pkg repo signing_command.
# Reads a SHA256 hex hash from stdin (what pkg repo pipes), signs it via the
# PIV signing agent socket, and outputs the format pkg expects: SIGNATURE,
# binary sig, CERT, PEM public key, END.
#
# pkg sends SHA256(data) as a hex string, and verifies the signature against
# SHA256(hex_string) — so we hash the hex string again before signing.
#
# The PIV signing agent (piv-sign-agent.py) runs on the local workstation
# with the YubiKey. Its Unix socket is forwarded to this host via SSH -R.
#
# Optional: PIV_AGENT_SOCK (forwarded socket path, default /tmp/piv-sign-agent.sock)
#           REPO_PUB (path to public key PEM file, overrides agent PUBKEY)
#

import base64
import hashlib
import os
import socket
import sys


def die(msg):
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(1)


def agent_request(sock_path, request):
    """Send a request to the PIV signing agent and return the response."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(60)
        s.connect(sock_path)
        s.sendall((request + "\n").encode())

        data = b""
        while b"\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
    except socket.error as e:
        die(f"cannot connect to PIV agent at {sock_path}: {e}")

    line = data.split(b"\n")[0].decode()
    if line.startswith("OK "):
        return line[3:]
    elif line.startswith("ERR "):
        die(f"agent error: {line[4:]}")
    else:
        die(f"unexpected agent response: {line}")


def find_repo_pub(sock_path):
    """Get the public key PEM: from file (REPO_PUB) or from the agent."""
    env_path = os.environ.get("REPO_PUB")
    if env_path and os.path.isfile(env_path):
        with open(env_path, "rb") as f:
            return f.read()

    # Same directory as this script (when scp'd alongside repo.pub)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(script_dir, "repo.pub")
    if os.path.isfile(path):
        with open(path, "rb") as f:
            return f.read()

    # Ask the agent
    b64 = agent_request(sock_path, "PUBKEY")
    return base64.b64decode(b64)


def main():
    sock_path = os.environ.get("PIV_AGENT_SOCK", "/tmp/piv-sign-agent.sock")

    # Get public key
    pub_pem = find_repo_pub(sock_path)

    # pkg repo sends SHA256(data) as a hex string on stdin. It doesn't close
    # stdin, so read one line only. pkg verifies against SHA256(hex_string),
    # so hash it again.
    hex_hash = sys.stdin.readline().strip()
    if not hex_hash:
        die("no hash received on stdin")

    double_hash = hashlib.sha256(hex_hash.encode()).digest()

    # Sign via PIV agent
    sig_b64 = agent_request(sock_path, f"SIGN SHA256 {double_hash.hex()}")
    sig = base64.b64decode(sig_b64)

    # Output in the format pkg expects
    sys.stdout.buffer.write(b"SIGNATURE\n")
    sys.stdout.buffer.write(sig)
    sys.stdout.buffer.write(b"\nCERT\n")
    sys.stdout.buffer.write(pub_pem)
    sys.stdout.buffer.write(b"END\n")
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
