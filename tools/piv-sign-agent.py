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
# PIV signing agent for FreeBSD pkg repo signing.
#
# Listens on a Unix socket and signs digests using the YubiKey PIV slot 9c
# via PKCS#11 (libykcs11). Designed to be forwarded over SSH (-R) so that
# pkg repo on a remote build host can sign through the local YubiKey.
#
# The PIN is fetched at the time of each signing request. A fresh PKCS#11
# session is opened per sign request to avoid stale session issues.
#
# Protocol (line-based over Unix socket):
#   Request:  SIGN SHA256 <hex-encoded-32-byte-digest>\n
#   Response: OK <base64-encoded-raw-PKCS1-signature>\n
#
#   Request:  PUBKEY\n
#   Response: OK <base64-encoded-PEM-public-key>\n
#
#   Errors:   ERR <message>\n
#
# Requires: yubico-piv-tool (provides libykcs11), ykman (for pubkey export)
# Optional: PIV_PIN (env var, static PIN)
#           PIV_PIN_COMMAND (env var, shell command that prints PIN to stdout)
#           PIV_AGENT_SOCK (socket path, default ~/.piv-sign-agent/agent.sock)
#           PIV_SLOT (PIV slot, default 9c)
#           PKCS11_MODULE (path to libykcs11, auto-detected)
#

import argparse
import atexit
import base64
import ctypes
import getpass
import hashlib
import os
import signal
import socket
import subprocess
import sys
import tempfile

# ── PKCS#11 constants ───────────────────────────────────────────────

CKF_SERIAL_SESSION = 0x04
CKF_RW_SESSION = 0x02
CKU_USER = 1
CKM_RSA_PKCS = 0x01
CKA_CLASS = 0x00
CKA_SIGN = 0x108
CKO_PRIVATE_KEY = 0x03

# DER-encoded DigestInfo prefix for SHA-256 (19 bytes)
SHA256_DER_PREFIX = bytes([
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
])


# ── PKCS#11 ctypes structures ───────────────────────────────────────


class CK_ATTRIBUTE(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_ulong),
        ("pValue", ctypes.c_void_p),
        ("ulValueLen", ctypes.c_ulong),
    ]


class CK_MECHANISM(ctypes.Structure):
    _fields_ = [
        ("mechanism", ctypes.c_ulong),
        ("pParameter", ctypes.c_void_p),
        ("ulParameterLen", ctypes.c_ulong),
    ]


# ── PKCS#11 one-shot signer ─────────────────────────────────────────


def pkcs11_sign(module_path, pin, digest, touch=True):
    """Open a PKCS#11 session, sign a digest, close the session.

    Opens a fresh session each time to avoid stale session issues (e.g.
    after ykman calls or YubiKey re-insertion). Returns raw PKCS#1 v1.5
    RSA signature bytes. Set touch=False to suppress touch prompts.
    """
    lib = ctypes.cdll.LoadLibrary(module_path)
    lib.C_Sign.argtypes = [
        ctypes.c_ulong, ctypes.c_char_p, ctypes.c_ulong,
        ctypes.c_char_p, ctypes.POINTER(ctypes.c_ulong),
    ]
    lib.C_Sign.restype = ctypes.c_ulong

    rv = lib.C_Initialize(None)
    if rv != 0:
        raise RuntimeError(f"C_Initialize failed: 0x{rv:x}")

    try:
        # Get first slot with a token
        slot_count = ctypes.c_ulong(0)
        lib.C_GetSlotList(1, None, ctypes.byref(slot_count))
        if slot_count.value == 0:
            raise RuntimeError("no YubiKey detected")
        slots = (ctypes.c_ulong * slot_count.value)()
        lib.C_GetSlotList(1, slots, ctypes.byref(slot_count))

        # Open session
        session = ctypes.c_ulong()
        rv = lib.C_OpenSession(
            slots[0], CKF_SERIAL_SESSION | CKF_RW_SESSION,
            None, None, ctypes.byref(session),
        )
        if rv != 0:
            raise RuntimeError(f"C_OpenSession failed: 0x{rv:x}")

        try:
            # Login
            pin_bytes = pin.encode()
            rv = lib.C_Login(session, CKU_USER, pin_bytes, len(pin_bytes))
            if rv != 0:
                raise RuntimeError(f"C_Login failed: 0x{rv:x} (wrong PIN?)")

            # Find signing key
            obj_class = ctypes.c_ulong(CKO_PRIVATE_KEY)
            sign_true = ctypes.c_ubyte(1)
            attrs = (CK_ATTRIBUTE * 2)(
                CK_ATTRIBUTE(CKA_CLASS, ctypes.addressof(obj_class),
                             ctypes.sizeof(obj_class)),
                CK_ATTRIBUTE(CKA_SIGN, ctypes.addressof(sign_true), 1),
            )
            rv = lib.C_FindObjectsInit(session, attrs, 2)
            if rv != 0:
                raise RuntimeError(f"C_FindObjectsInit failed: 0x{rv:x}")
            key = ctypes.c_ulong()
            count = ctypes.c_ulong()
            lib.C_FindObjects(session, ctypes.byref(key), 1,
                              ctypes.byref(count))
            lib.C_FindObjectsFinal(session)
            if count.value == 0:
                raise RuntimeError("no signing key found in PIV slot")

            # Build DigestInfo
            digest_info = SHA256_DER_PREFIX + digest
            if len(digest_info) != 51:
                raise ValueError(f"bad DigestInfo length: {len(digest_info)}")

            # Sign
            mech = CK_MECHANISM(CKM_RSA_PKCS, None, 0)
            rv = lib.C_SignInit(session, ctypes.byref(mech), key)
            if rv != 0:
                raise RuntimeError(f"C_SignInit failed: 0x{rv:x}")

            if touch:
                sys.stderr.write("Touch your YubiKey...\n")
                sys.stderr.flush()

            sig_len = ctypes.c_ulong(256)
            sig_buf = ctypes.create_string_buffer(256)
            rv = lib.C_Sign(session, digest_info,
                            ctypes.c_ulong(len(digest_info)),
                            sig_buf, ctypes.byref(sig_len))
            if rv != 0:
                raise RuntimeError(f"C_Sign failed: 0x{rv:x}")

            return sig_buf.raw[:sig_len.value]
        finally:
            lib.C_Logout(session)
            lib.C_CloseSession(session)
    finally:
        lib.C_Finalize(None)


# ── Helpers ──────────────────────────────────────────────────────────


def find_pkcs11_module():
    """Auto-detect the libykcs11 PKCS#11 module path."""
    env = os.environ.get("PKCS11_MODULE")
    if env:
        return env

    candidates = [
        "/opt/homebrew/lib/libykcs11.dylib",       # macOS Homebrew (ARM)
        "/usr/local/lib/libykcs11.dylib",           # macOS Homebrew (Intel)
        "/usr/lib/x86_64-linux-gnu/libykcs11.so",   # Debian/Ubuntu
        "/usr/lib/libykcs11.so",                    # Other Linux
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path

    raise RuntimeError(
        "libykcs11 not found. Install yubico-piv-tool or set PKCS11_MODULE."
    )


def get_pin(pin_command=None):
    """Get the PIV PIN from environment, command, or interactive prompt.

    Resolution order:
    1. PIV_PIN environment variable
    2. pin_command argument or PIV_PIN_COMMAND env var (shell command)
    3. Interactive prompt (getpass)
    """
    pin = os.environ.get("PIV_PIN")
    if pin:
        return pin

    cmd = pin_command or os.environ.get("PIV_PIN_COMMAND")
    if cmd:
        try:
            result = subprocess.run(
                cmd, shell=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
            raise RuntimeError(
                f"pin command failed (exit {result.returncode}): {result.stderr.strip()}"
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("pin command timed out")

    try:
        return getpass.getpass("PIV PIN: ")
    except EOFError:
        raise RuntimeError(
            "PIV PIN not available. Set PIV_PIN, use --pin-command, or run interactively."
        )


def get_pubkey(slot_id="9c"):
    """Export the PIV public key in PEM format via ykman."""
    result = subprocess.run(
        ["ykman", "piv", "keys", "export", slot_id, "-"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ykman piv keys export failed: {result.stderr}")
    return result.stdout.encode()


def default_socket_path():
    """Return the default agent socket path."""
    env = os.environ.get("PIV_AGENT_SOCK")
    if env:
        return env
    sock_dir = os.path.join(os.path.expanduser("~"), ".piv-sign-agent")
    return os.path.join(sock_dir, "agent.sock")


# ── Socket server ────────────────────────────────────────────────────


class PIVSignAgent:
    """Unix socket server that signs digests via YubiKey PIV."""

    def __init__(self, module_path, pubkey_pem, sock_path,
                 pin_command=None, touch=True):
        self.module_path = module_path
        self.pubkey_pem = pubkey_pem
        self.pubkey_b64 = base64.b64encode(pubkey_pem).decode()
        self.sock_path = sock_path
        self.pin_command = pin_command
        self.touch = touch
        self.server = None

    def handle_sign(self, hex_digest):
        """Fetch PIN, open PKCS#11, sign, close. Returns response string."""
        try:
            digest = bytes.fromhex(hex_digest)
        except ValueError:
            return "ERR invalid hex digest"
        if len(digest) != 32:
            return f"ERR digest must be 32 bytes, got {len(digest)}"

        # Fetch PIN
        sys.stderr.write("Fetching PIV PIN...\n")
        sys.stderr.flush()
        try:
            pin = get_pin(self.pin_command)
        except RuntimeError as e:
            return f"ERR {e}"

        # Sign with a fresh PKCS#11 session
        if self.touch:
            sys.stderr.write("\n  >>> Touch your YubiKey NOW! <<<\n\n")
            sys.stderr.flush()
        try:
            sig = pkcs11_sign(self.module_path, pin, digest, self.touch)
            if self.touch:
                sys.stderr.write("Signature complete.\n")
                sys.stderr.flush()
            return f"OK {base64.b64encode(sig).decode()}"
        except RuntimeError as e:
            return f"ERR {e}"

    def handle_request(self, line):
        """Process a single request line. Returns response string."""
        line = line.strip()
        if not line:
            return "ERR empty request"

        if line == "PUBKEY":
            return f"OK {self.pubkey_b64}"

        if line.startswith("SIGN SHA256 "):
            hex_digest = line[len("SIGN SHA256 "):]
            return self.handle_sign(hex_digest)

        return "ERR unknown command"

    def handle_connection(self, conn):
        """Handle one client connection (one request-response)."""
        try:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if len(data) > 8192:
                    conn.sendall(b"ERR request too large\n")
                    return

            if not data:
                return

            line = data.split(b"\n")[0].decode("utf-8", errors="replace")
            response = self.handle_request(line)
            conn.sendall((response + "\n").encode())
        except Exception as e:
            try:
                conn.sendall(f"ERR {e}\n".encode())
            except Exception:
                pass

    def run(self):
        """Start the agent and listen for connections."""
        sock_dir = os.path.dirname(self.sock_path)
        os.makedirs(sock_dir, mode=0o700, exist_ok=True)

        # Remove stale socket
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)

        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.sock_path)
        os.chmod(self.sock_path, 0o600)
        self.server.listen(1)

        atexit.register(self.cleanup)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

        sys.stderr.write(f"PIV signing agent listening on {self.sock_path}\n")
        sys.stderr.flush()

        while True:
            conn, _ = self.server.accept()
            try:
                self.handle_connection(conn)
            finally:
                conn.close()

    def cleanup(self):
        """Remove socket file on exit."""
        if self.server:
            self.server.close()
            self.server = None
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)


# ── Self-test ────────────────────────────────────────────────────────


def self_test(module_path, pubkey_pem, pin_command=None, touch=True):
    """Fetch PIN, sign a test digest, verify the signature."""
    test_data = b"piv-sign-agent self-test"
    digest = hashlib.sha256(test_data).digest()

    sys.stderr.write("Self-test: fetching PIN and signing...\n")
    try:
        pin = get_pin(pin_command)
    except RuntimeError as e:
        sys.stderr.write(f"Self-test: FAILED — {e}\n")
        return False

    try:
        sig = pkcs11_sign(module_path, pin, digest, touch)
    except RuntimeError as e:
        sys.stderr.write(f"Self-test: FAILED — {e}\n")
        return False
    sys.stderr.write(f"Self-test: got {len(sig)} byte signature\n")

    # Verify with openssl
    with tempfile.NamedTemporaryFile(suffix=".pem") as pub_f, \
         tempfile.NamedTemporaryFile(suffix=".sig") as sig_f:
        pub_f.write(pubkey_pem)
        pub_f.flush()
        sig_f.write(sig)
        sig_f.flush()

        result = subprocess.run(
            [
                "openssl", "rsautl", "-verify",
                "-pubin", "-inkey", pub_f.name,
                "-in", sig_f.name,
            ],
            capture_output=True,
        )
        if result.returncode != 0:
            sys.stderr.write("Self-test: FAILED — openssl verify error\n")
            return False

        recovered = result.stdout[-32:]
        if recovered == digest:
            sys.stderr.write("Self-test: PASSED\n")
            return True
        else:
            sys.stderr.write(
                f"Self-test: FAILED\n"
                f"  expected: {digest.hex()}\n"
                f"  got:      {recovered.hex()}\n"
            )
            return False


# ── Main ─────────────────────────────────────────────────────────────


def load_dotenv():
    """Load .env file from the repo root into os.environ (no-op if missing)."""
    env_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), os.pardir, ".env"
    )
    try:
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if not key:
                    continue
                os.environ.setdefault(key, value)
    except FileNotFoundError:
        pass


def main():
    load_dotenv()

    parser = argparse.ArgumentParser(
        description="PIV signing agent for FreeBSD pkg repo signing",
    )
    parser.add_argument(
        "--socket",
        default=default_socket_path(),
        help="Unix socket path (default: %(default)s)",
    )
    parser.add_argument(
        "--slot",
        default=os.environ.get("PIV_SLOT", "9c"),
        help="PIV slot (default: %(default)s)",
    )
    parser.add_argument(
        "--pin-command",
        default=os.environ.get("PIV_PIN_COMMAND"),
        help="Shell command that prints the PIV PIN to stdout "
             "(default: PIV_PIN_COMMAND env var)",
    )
    parser.add_argument(
        "--touch", dest="touch",
        action="store_true", default=True,
        help="Show touch prompts (default)",
    )
    parser.add_argument(
        "--no-touch", dest="touch",
        action="store_false",
        help="Suppress touch prompts (for YubiKeys with touch disabled)",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Run self-test (sign and verify a test digest), then exit",
    )
    args = parser.parse_args()

    # Find PKCS#11 module
    try:
        module_path = find_pkcs11_module()
    except RuntimeError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        sys.exit(1)
    sys.stderr.write(f"PKCS#11 module: {module_path}\n")

    # Export public key (before any PKCS#11 — ykman would invalidate sessions)
    try:
        pubkey_pem = get_pubkey(args.slot)
    except RuntimeError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        sys.exit(1)
    sys.stderr.write(f"Public key loaded ({len(pubkey_pem)} bytes)\n")

    # Self-test mode
    if args.test:
        ok = self_test(module_path, pubkey_pem, args.pin_command, args.touch)
        sys.exit(0 if ok else 1)

    # Run agent
    agent = PIVSignAgent(module_path, pubkey_pem, args.socket,
                         args.pin_command, args.touch)
    try:
        agent.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
