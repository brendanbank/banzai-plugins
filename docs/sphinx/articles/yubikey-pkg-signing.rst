=====================================================
Signing FreeBSD pkg Repositories with a YubiKey
=====================================================

FreeBSD's ``pkg`` supports cryptographic signing of package repositories.
It uses its own signing protocol with a double-hash scheme and a specific
stdin/stdout contract for signing commands. This article walks through signing a
``pkg repo`` with a key stored on a YubiKey's PIV applet via PKCS#11, including
socket forwarding for remote builds.

The scripts and tools described here are part of the
`banzai-plugins <https://github.com/brendanbank/banzai-plugins>`_ repository.

.. note::

   An earlier version of this setup used the YubiKey's GPG applet with
   ``gpg-connect-agent`` and Assuan protocol over a forwarded gpg-agent socket.
   That approach works but is fragile: gpg-agent socket forwarding requires
   killing the remote agent in a separate SSH call, the Assuan protocol requires
   percent-encoding and S-expression parsing, and gpg-agent socket conflicts
   with SSH auth when both use the same agent. The PIV approach described here
   uses an independent applet with a standard PKCS#11 interface and a simple
   custom socket protocol.

Why hardware-backed signing?
----------------------------

A pkg repository signing key is a high-value target. If the private key is
compromised, an attacker can push malicious packages to every machine that
trusts the repo. Storing the signing key on a YubiKey means the private key
never exists on disk -- signing operations happen on the hardware token, which
is designed to prevent extraction of private keys.

How pkg signing actually works
------------------------------

Before writing any code, you need to understand what ``pkg repo`` actually does
when it signs. The
`pkg-repo(8) <https://man.freebsd.org/cgi/man.cgi?query=pkg-repo&sektion=8>`_
man page [1]_ documents the output format (``SIGNATURE``/``CERT``/``END``) and
states that the signing command receives "the SHA256 of the repository catalogue
on its stdin." However, it does not describe the double-hash verification
scheme, the fact that stdin remains open, or how fingerprints are computed.

When you run:

.. code-block:: sh

   pkg repo /path/to/repo/ signing_command: /path/to/sign.sh

pkg computes ``SHA256(data)`` as a **64-character lowercase hex string** and
pipes it to your signing command's stdin. Your command must output a response in
this format::

   SIGNATURE
   <binary signature bytes>
   CERT
   <PEM public key>
   END

The critical detail: **pkg keeps stdin open** while it waits for the signing
command's response, only closing it during cleanup [5]_. This means ``cat`` will
deadlock waiting for EOF. The official example script [3]_ in the pkg repository
uses ``read -t 2`` (with a 2-second timeout) to handle this.

The double hash
~~~~~~~~~~~~~~~

pkg sends ``SHA256_hex(data)`` -- a hex string --
on stdin. But when it *verifies* the signature, it computes
``SHA256(hex_string)`` and checks the signature against *that*. The hash that
gets signed is:

.. code-block:: text

   SHA256(SHA256_hex(data))

This is a double hash: SHA256 of the data produces a hex string, then SHA256 of
that hex string produces the 32-byte digest that ends up in the RSA signature's
DigestInfo structure.

If you sign the hex string directly (without hashing it again),
``openssl dgst -verify`` will validate your signature -- but ``pkg`` will
reject it. ``openssl dgst -verify`` tests a single hash, not the double hash
that pkg expects, so it is not a valid test for pkg signatures.

The correct signature format is::

   RSA(PKCS#1 v1.5(DigestInfo(SHA256_OID, SHA256(hex_string))))

This is confirmed by the verification code in ``libpkg/pkgsign_ossl.c`` [4]_.
The function ``ossl_verify_cb`` calls ``pkg_checksum_fd()`` to get the hex hash,
then passes the 64-byte hex string directly to ``EVP_PKEY_verify`` with a
custom digest ``EVP_md_pkg_sha1()``. This custom digest has the SHA-1 OID but
an overridden result size of 64. In practice with OpenSSL 3.x, signatures using
the SHA-256 OID and 32-byte hash also verify correctly.

Fingerprints
~~~~~~~~~~~~

pkg identifies trusted signing keys by fingerprint. The fingerprint is
``SHA256`` of the **entire PEM file** -- including the
``-----BEGIN/END-----`` headers and trailing newline:

.. code-block:: sh

   # Correct:
   shasum -a 256 repo.pub

   # WRONG -- gives a different hash:
   openssl rsa -pubin -outform DER < repo.pub | shasum -a 256

The fingerprint is not a hash of the DER-encoded public key material. It's a
hash of the PEM file as-is [6]_.

Setting up the PIV signing key
------------------------------

The signing key lives in the YubiKey's PIV applet, slot **9c** (Digital
Signature). PIV is independent from the GPG applet -- no contention with
GPG/SSH auth.

Check your PIV slot:

.. code-block:: sh

   ykman piv info

You should see something like::

   Slot 9C (SIGNATURE):
     Private key type: RSA2048
     Public key type:  RSA2048
     Subject DN:       CN=repo signing
     PIN required:     ALWAYS
     Touch required:   ALWAYS

If you need to generate a key in the PIV slot:

.. code-block:: sh

   ykman piv keys generate -a RSA2048 --touch-policy ALWAYS --pin-policy ALWAYS 9c pubkey.pem

Export the public key in PEM format:

.. code-block:: sh

   ykman piv keys export 9c repo.pub

This gives you a standard PKCS#8 PEM file that pkg can use directly -- no
format conversion needed (unlike GPG keys which require S-expression parsing
and DER construction).

The PIV signing agent
---------------------

The signing agent
(`piv-sign-agent.py <https://github.com/brendanbank/banzai-plugins/blob/main/tools/piv-sign-agent.py>`_)
runs on your local workstation (where the YubiKey is plugged in) and listens on
a Unix socket. It signs digests using the YubiKey PIV slot via PKCS#11
(``libykcs11``), using Python's ``ctypes`` to call the PKCS#11 functions
directly -- no pip dependencies required beyond what Homebrew's
``yubico-piv-tool`` provides.

.. mermaid::

   flowchart LR
       subgraph remote["Remote build host"]
           sign["sign-repo.py"]
       end
       subgraph local["Local workstation"]
           agent["piv-sign-agent.py"]
           yubikey[("YubiKey PIV")]
           agent --- yubikey
       end
       sign -- "&ensp;ssh -R socket&ensp;" --> agent

The agent protocol is line-based:

.. code-block:: text

   Request:  SIGN SHA256 <hex-encoded-32-byte-digest>\n
   Response: OK <base64-encoded-raw-PKCS1-signature>\n

   Request:  PUBKEY\n
   Response: OK <base64-encoded-PEM-public-key>\n

   Errors:   ERR <message>\n

A fresh PKCS#11 session is opened for each signing request to avoid stale
session issues (e.g. after ``ykman`` calls or YubiKey re-insertion).

Starting the agent:

.. code-block:: sh

   # With a password manager command for PIN retrieval:
   python3 piv-sign-agent.py --pin-command "your-pin-retrieval-command"

   # With PIN from environment:
   PIV_PIN=123456 python3 piv-sign-agent.py

   # Interactive (prompts for PIN at each signing request):
   python3 piv-sign-agent.py

   # Self-test (sign and verify a test digest):
   python3 piv-sign-agent.py --test --pin-command "your-pin-retrieval-command"

   # Suppress touch prompts (for YubiKeys with touch disabled):
   python3 piv-sign-agent.py --no-touch --pin-command "..."

PKCS#11 signing flow
~~~~~~~~~~~~~~~~~~~~

The PKCS#11 flow for each signing request:

.. code-block:: text

   C_Initialize(None)
   C_GetSlotList(tokenPresent=True)  ->  slot
   C_OpenSession(slot, CKF_SERIAL_SESSION | CKF_RW_SESSION)  ->  session
   C_Login(session, CKU_USER, pin)
   C_FindObjectsInit(session, [CKA_CLASS=CKO_PRIVATE_KEY, CKA_SIGN=True])
   C_FindObjects(session)  ->  key_handle
   C_FindObjectsFinal(session)
   C_SignInit(session, CKM_RSA_PKCS, key_handle)
   C_Sign(session, digest_info, sig_buf)  ->  signature    # touch required here

``CKM_RSA_PKCS`` performs raw PKCS#1 v1.5 padding -- the caller must provide
the DER-encoded DigestInfo structure:

.. code-block:: python

   SHA256_DER_PREFIX = bytes([
       0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
       0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
       0x00, 0x04, 0x20
   ])
   digest_info = SHA256_DER_PREFIX + sha256_hash  # 19 + 32 = 51 bytes

The signing command
-------------------

The signing command
(`sign-repo.py <https://github.com/brendanbank/banzai-plugins/blob/main/tools/sign-repo.py>`_)
runs on the **remote build host**, called by ``pkg repo`` as the
``signing_command``. It connects to the forwarded PIV agent socket, sends the
double-hashed digest, and outputs the result in pkg's expected format.

.. code-block:: python

   #!/usr/bin/env python3

   import base64
   import hashlib
   import os
   import socket
   import sys


   def die(msg):
       sys.stderr.write(f"ERROR: {msg}\n")
       sys.exit(1)


   def agent_request(sock_path, request):
       """Send a request to the PIV signing agent."""
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
       """Get the public key PEM: from file or from the agent."""
       env_path = os.environ.get("REPO_PUB")
       if env_path and os.path.isfile(env_path):
           with open(env_path, "rb") as f:
               return f.read()
       script_dir = os.path.dirname(os.path.abspath(__file__))
       path = os.path.join(script_dir, "repo.pub")
       if os.path.isfile(path):
           with open(path, "rb") as f:
               return f.read()
       # Ask the agent
       b64 = agent_request(sock_path, "PUBKEY")
       return base64.b64decode(b64)


   def main():
       sock_path = os.environ.get("PIV_AGENT_SOCK",
                                  "/tmp/piv-sign-agent.sock")
       pub_pem = find_repo_pub(sock_path)

       # pkg repo sends SHA256(data) as a hex string on stdin.
       # It doesn't close stdin, so read one line only.
       # pkg verifies against SHA256(hex_string), so hash it again.
       hex_hash = sys.stdin.readline().strip()
       if not hex_hash:
           die("no hash received on stdin")
       double_hash = hashlib.sha256(hex_hash.encode()).digest()

       # Sign via PIV agent
       sig_b64 = agent_request(sock_path,
                               f"SIGN SHA256 {double_hash.hex()}")
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

Socket forwarding for remote builds
------------------------------------

In many setups, packages are built on a remote FreeBSD machine but the YubiKey
is plugged into your local workstation. SSH socket forwarding solves this: the
agent's Unix socket is forwarded to the remote host via ``ssh -R``.

.. code-block:: sh

   # Start the PIV signing agent locally
   python3 piv-sign-agent.py --pin-command "your-pin-retrieval-command" &

   # Forward the agent socket to the remote host
   LOCAL_PIV_SOCK="${HOME}/.piv-sign-agent/agent.sock"
   REMOTE_PIV_SOCK="/tmp/piv-sign-agent.sock"

   # Remove stale remote socket, then connect with forwarding
   ssh remote-host "rm -f ${REMOTE_PIV_SOCK}"
   ssh -R "${REMOTE_PIV_SOCK}:${LOCAL_PIV_SOCK}" remote-host \
       "PIV_AGENT_SOCK=${REMOTE_PIV_SOCK} \
        pkg repo /path/to/repo/ signing_command: /path/to/sign-repo.py"

Unlike GPG agent forwarding, this approach is straightforward: there is no
remote agent to kill, the socket is just a file, and the protocol is a simple
line-based exchange over the forwarded socket.

Putting it together: the build script
-------------------------------------

Here's the signing section of a build script that builds packages on a remote
FreeBSD host and signs the repo via PIV agent socket forwarding:

.. code-block:: sh

   # Upload the signing script and public key
   rsync -aq -e ssh tools/sign-repo.py Keys/repo.pub \
       "${FIREWALL}:${REMOTE_REPO_DIR}/"

   # Ensure piv-sign-agent.py is running locally
   LOCAL_PIV_SOCK="${PIV_AGENT_SOCK:-${HOME}/.piv-sign-agent/agent.sock}"
   if [ ! -S "${LOCAL_PIV_SOCK}" ]; then
       echo "ERROR: PIV signing agent not running" >&2
       exit 1
   fi

   REMOTE_PIV_SOCK="/tmp/piv-sign-agent.sock"

   # Remove stale remote socket before forwarding
   ssh "${FIREWALL}" "rm -f ${REMOTE_PIV_SOCK}"

   # Sign with forwarded PIV agent socket
   ssh -R "${REMOTE_PIV_SOCK}:${LOCAL_PIV_SOCK}" "${FIREWALL}" \
       "PIV_AGENT_SOCK=${REMOTE_PIV_SOCK} \
        pkg repo ${REMOTE_REPO_DIR}/ signing_command: ${REMOTE_REPO_DIR}/sign-repo.py"

   # Verify signing succeeded (pkg repo exits 0 even on failure)
   ssh "${FIREWALL}" "test -f ${REMOTE_REPO_DIR}/meta.conf" || {
       echo "ERROR: Repo signing failed" >&2
       exit 1
   }

Note the ``meta.conf`` check: ``pkg repo`` exits 0 even when signing fails, so
you need to verify the output explicitly.

Client-side setup
-----------------

On each machine that should trust the repo, install the fingerprint [2]_:

.. code-block:: sh

   mkdir -p /usr/local/etc/pkg/fingerprints/myrepo/trusted
   mkdir -p /usr/local/etc/pkg/fingerprints/myrepo/revoked

   # Fingerprint is SHA256 of the PEM file (not the DER key)
   FINGERPRINT=$(shasum -a 256 repo.pub | awk '{print $1}')

   cat > /usr/local/etc/pkg/fingerprints/myrepo/trusted/repo.fingerprint <<EOF
   function: sha256
   fingerprint: ${FINGERPRINT}
   EOF

Then add the repository configuration:

.. code-block:: sh

   cat > /usr/local/etc/pkg/repos/myrepo.conf <<'EOF'
   myrepo: {
     url: "https://example.com/packages/${ABI}/repo",
     signature_type: "fingerprints",
     fingerprints: "/usr/local/etc/pkg/fingerprints/myrepo",
     enabled: yes
   }
   EOF

   pkg update -f -r myrepo

Verifying signatures manually
-----------------------------

You can't use ``openssl dgst -verify`` -- it tests the wrong thing. Instead,
extract and inspect the DigestInfo:

.. code-block:: sh

   # Extract signature components from the repo archive
   tar -xf data.pkg data data.pub data.sig

   # Decrypt the signature to see the DigestInfo
   openssl rsautl -verify -pubin -inkey data.pub -in data.sig 2>/dev/null \
       | od -A x -t x1 | tail -4

   # Compute the expected hash (double SHA256):
   printf '%s' "$(openssl dgst -sha256 -hex data | awk '{print $NF}')" \
       | openssl dgst -sha256 -hex | awk '{print $NF}'

The last 32 bytes of the DigestInfo from the first command should match the
hash from the second command.

Summary of pitfalls
-------------------

.. list-table::
   :header-rows: 1
   :widths: 25 35 40

   * - Pitfall
     - Symptom
     - Fix
   * - Signing hex hash directly
     - ``openssl dgst -verify`` passes but ``pkg`` rejects
     - Hash the hex string again with SHA256 before signing
   * - Using ``cat`` to read stdin
     - Signing command deadlocks
     - Use ``read -t 2`` or ``readline()`` -- pkg keeps stdin open
   * - Fingerprint from DER key
     - "No trusted public keys found"
     - Fingerprint is ``SHA256(PEM file)``, headers and all
   * - Testing with ``openssl dgst -verify``
     - Valid signatures appear to fail
     - Tests single hash, not pkg's double hash; use manual DigestInfo extraction
   * - ``pkg repo`` exit code
     - Build succeeds but repo is unsigned
     - Check for ``meta.conf`` existence after ``pkg repo``
   * - ``ykman`` invalidates PKCS#11 sessions
     - ``C_Sign`` fails with ``0x101``
     - Export public key with ``ykman`` *before* opening PKCS#11 session
   * - Touch timeout on YubiKey
     - ``C_Sign`` returns ``0x101`` after ~15 seconds
     - Touch the YubiKey when prompted; ``0x101`` is Yubico's ``CKR_CANCEL``

References
----------

.. [1] `pkg-repo(8) man page <https://man.freebsd.org/cgi/man.cgi?query=pkg-repo&sektion=8>`_
   -- documents the ``signing_command`` output format and states that the SHA256
   of the catalogue is passed on stdin.

.. [2] `pkg.conf(5) man page <https://man.freebsd.org/cgi/man.cgi?query=pkg.conf&sektion=5>`_
   -- documents ``SIGNATURE_TYPE``, ``FINGERPRINTS``, and the fingerprint file
   format (``function: sha256``, ``fingerprint: ...``).

.. [3] `scripts/sign.sh <https://github.com/freebsd/pkg/blob/main/scripts/sign.sh>`_
   -- the official example signing script in the freebsd/pkg repository. Uses
   ``read -t 2`` and ``openssl dgst -sign -sha256``.

.. [4] `libpkg/pkgsign_ossl.c <https://github.com/freebsd/pkg/blob/main/libpkg/pkgsign_ossl.c>`_
   -- OpenSSL signing and verification implementation. Contains
   ``EVP_md_pkg_sha1()`` (custom digest with SHA-1 OID, result size 64) and
   ``ossl_verify_cb`` (verification using ``pkg_checksum_fd`` with
   ``PKG_HASH_TYPE_SHA256_HEX``).

.. [5] `libpkg/pkg_repo_create.c <https://github.com/freebsd/pkg/blob/main/libpkg/pkg_repo_create.c>`_
   -- repository creation code. Shows the hash written to stdin via
   ``fprintf``/``fflush``, with ``fclose`` deferred until after reading the
   response.

.. [6] `libpkg/pkg_repo.c <https://github.com/freebsd/pkg/blob/main/libpkg/pkg_repo.c>`_
   -- fingerprint verification code. Computes ``pkg_checksum_data(s->cert,
   s->certlen, PKG_HASH_TYPE_SHA256_HEX)`` where ``cert`` is the PEM data
   returned by the signing command.
