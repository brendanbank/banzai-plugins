=====================================================
Signing FreeBSD pkg Repositories with a YubiKey
=====================================================

FreeBSD's ``pkg`` supports cryptographic signing of package repositories. Its
signing protocol differs from standard RSA-SHA256 in ways that the documentation
does not cover in detail. This article walks through signing a ``pkg repo`` with
a GPG key stored on a YubiKey, including GPG agent forwarding for remote builds.

Why hardware-backed signing?
----------------------------

A pkg repository signing key is a high-value target. If the private key is
compromised, an attacker can push malicious packages to every machine that
trusts the repo. Storing the signing key on a YubiKey means the private key
never exists on disk -- signing operations happen on the hardware token, and
extraction is not possible.

How pkg signing actually works
------------------------------

Before writing any code, you need to understand what ``pkg repo`` actually does
when it signs. **pkg uses its own signing protocol**, and the documentation doesn't spell out
the details.

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

The critical detail: **pkg does not close stdin** after writing the hash. This
means ``cat`` will hang forever waiting for EOF. You must use ``read -r``
instead.

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
reject it. Note that ``openssl dgst -verify`` is not a valid test for pkg
signatures -- **even OPNsense's own official repository signatures fail
openssl dgst -verify**.

The correct signature format is::

   RSA(PKCS#1 v1.5(DigestInfo(SHA256_OID, SHA256(hex_string))))

This is confirmed by reading ``libpkg/pkgsign_ossl.c`` in the
`freebsd/pkg <https://github.com/freebsd/pkg>`_ source. The verification
function ``ossl_verify_cb`` calls ``pkg_checksum_fd()`` to get the hex hash,
then passes the 64-byte hex string directly to ``EVP_PKEY_verify`` with a
custom digest ``EVP_md_pkg_sha1()``. This custom digest has the SHA-1 OID but
an overridden result size of 64. In practice
with OpenSSL 3.x, signatures using the SHA-256 OID and 32-byte hash also verify
correctly.

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
hash of the PEM file as-is.

Setting up the GPG signing key
------------------------------

Generate or identify your signing subkey
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If you already have a GPG key on your YubiKey, identify the signing subkey:

.. code-block:: sh

   gpg --list-keys --with-keygrip your@email.com

Look for a subkey with ``[S]`` (signing) capability and note its **keygrip** --
a 40-character hex string. The keygrip identifies the key to ``gpg-agent``
regardless of the key's OpenPGP metadata.

If you need to generate a new signing subkey:

.. code-block:: sh

   gpg --edit-key your@email.com
   > addkey       # Choose RSA (sign only), 2048 or 4096 bits
   > save
   gpg --edit-key your@email.com
   > keytocard     # Move the subkey to the YubiKey
   > save

Export the public key in PEM format
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

pkg needs a PKCS#8 PEM public key, not a GPG public key. If the key was created
outside GPG and imported, you may already have the PEM file. If the key was
generated on the YubiKey via GPG, you can extract it with ``gpg-connect-agent``
and convert it to PEM. ``gpg-connect-agent`` returns key material as
S-expressions -- a length-prefixed binary format (e.g. ``3:rsa`` means "3 bytes:
rsa", ``1:n512:<bytes>`` means "field n, 512 bytes of data"):

.. code-block:: sh

   python3 << 'PYEOF' > repo.pub
   import subprocess, re, base64, sys

   KEYGRIP = "<your-keygrip-here>"

   result = subprocess.run(
       ["gpg-connect-agent", f"READKEY {KEYGRIP}", "/bye"],
       capture_output=True
   )

   # Decode Assuan protocol D lines (%-encoded binary)
   data_parts = []
   for line in result.stdout.split(b'\n'):
       if line.startswith(b'D '):
           part = line[2:]
           decoded = b''
           i = 0
           while i < len(part):
               if part[i:i+1] == b'%' and i+2 < len(part):
                   decoded += bytes([int(part[i+1:i+3], 16)])
                   i += 3
               else:
                   decoded += part[i:i+1]
                   i += 1
           data_parts.append(decoded)
   sexp = b''.join(data_parts)

   # Parse n and e from S-expression:
   # (10:public-key(3:rsa(1:n<len>:<n>)(1:e<len>:<e>)))
   n_match = re.search(rb'\(1:n(\d+):', sexp)
   n_len = int(n_match.group(1))
   n_bytes = sexp[n_match.end():n_match.end()+n_len]
   e_start = n_match.end() + n_len
   e_match = re.search(rb'\(1:e(\d+):', sexp[e_start:])
   e_len = int(e_match.group(1))
   e_bytes = sexp[e_start + e_match.end():e_start + e_match.end() + e_len]

   n_int = int.from_bytes(n_bytes, 'big')
   e_int = int.from_bytes(e_bytes, 'big')

   # Build DER-encoded SubjectPublicKeyInfo
   def der_integer(value):
       b = value.to_bytes((value.bit_length() + 8) // 8, 'big')
       return b'\x02' + der_length(len(b)) + b
   def der_length(l):
       if l < 128: return bytes([l])
       elif l < 256: return b'\x81' + bytes([l])
       else: return b'\x82' + l.to_bytes(2, 'big')
   def der_sequence(data):
       return b'\x30' + der_length(len(data)) + data

   rsa_pub = der_sequence(der_integer(n_int) + der_integer(e_int))
   rsa_oid = b'\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00'
   bit_string = b'\x03' + der_length(len(rsa_pub) + 1) + b'\x00' + rsa_pub
   spki = der_sequence(rsa_oid + bit_string)

   pem = b'-----BEGIN PUBLIC KEY-----\n'
   pem += base64.encodebytes(spki)
   pem += b'-----END PUBLIC KEY-----\n'
   sys.stdout.buffer.write(pem)
   PYEOF

This uses ``READKEY`` to read the raw RSA public key from the YubiKey, parses
the modulus and exponent from the gpg-agent S-expression, and constructs a
standard PKCS#8 PEM file. The result should look like::

   -----BEGIN PUBLIC KEY-----
   MIICIjANBgkqhkiG9w0BAQEFAAOC...
   -----END PUBLIC KEY-----

The signing script
------------------

This script is called by ``pkg repo`` as the ``signing_command``. It reads the
hex hash from stdin, performs the double hash, signs via ``gpg-agent``, and
outputs the result in pkg's expected format.

.. code-block:: sh

   #!/bin/sh
   set -e

   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
   REPO_PUB="${REPO_PUB:-${SCRIPT_DIR}/repo.pub}"

   # Keygrip of the GPG signing subkey on the YubiKey
   KEYGRIP="${GPG_SIGN_KEYGRIP:-<your-keygrip-here>}"

   [ -f "${REPO_PUB}" ] || { echo "ERROR: ${REPO_PUB} not found" >&2; exit 1; }

   for cmd in gpg-connect-agent python3 openssl; do
       command -v "$cmd" >/dev/null 2>&1 || {
           echo "ERROR: $cmd not found" >&2; exit 1
       }
   done

   SIG=$(mktemp)
   trap 'rm -f "${SIG}"' EXIT

   # pkg sends SHA256(data) as hex on stdin (doesn't close stdin -- use read).
   # pkg verifies against SHA256(hex_string), so hash it again.
   read -r HEX_HASH
   HASH=$(printf '%s' "${HEX_HASH}" | openssl dgst -sha256 -hex 2>/dev/null \
       | awk '{print $NF}' | tr 'a-f' 'A-F')

   # Sign via gpg-agent PKSIGN.
   # SETHASH --hash=sha256 tells the agent the hash algorithm;
   # PKSIGN wraps it in DigestInfo(SHA256_OID, hash) and RSA-signs it.
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

   # Parse raw RSA signature from S-expression:
   # (7:sig-val(3:rsa(1:s<len>:<sig>)))
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

Why gpg-connect-agent instead of gpg --sign?
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``gpg --sign`` produces OpenPGP-format signatures, which are completely
different from what pkg expects. pkg needs a raw PKCS#1 v1.5 RSA signature. The
``gpg-connect-agent`` command talks directly to the agent daemon using the
Assuan protocol, giving us access to the low-level ``PKSIGN`` operation that
returns a raw RSA signature wrapped in an S-expression.

The Assuan protocol is GnuPG's line-based IPC protocol. Responses come as
single-letter prefixed lines: ``OK`` for success, ``ERR`` for errors, and
``D`` for data. Binary payloads are returned on ``D`` lines with special bytes
percent-encoded (e.g. ``%25`` for ``%``, ``%0A`` for newline). Large responses
may span multiple ``D`` lines that need to be concatenated after decoding.

The signing flow is:

1. ``SIGKEY <keygrip>`` -- select the signing key
2. ``SETHASH --hash=sha256 <hex>`` -- set the hash to sign
3. ``PKSIGN`` -- produce the signature

The agent returns the signature on ``D`` lines as an S-expression:
``(sig-val(rsa(s<len>:<bytes>)))``. The Python code decodes the percent-encoded
``D`` lines and extracts the raw signature bytes.

Why Python?
~~~~~~~~~~~

The Assuan ``D`` line decoding and S-expression binary parsing are awkward in
pure shell. Python is available on FreeBSD by default and handles binary data
cleanly.

GPG agent forwarding for remote builds
--------------------------------------

In many setups, packages are built on a remote FreeBSD machine but the YubiKey
is plugged into your local workstation. GPG agent forwarding over SSH solves
this: the remote machine's ``gpg-connect-agent`` commands are transparently
forwarded to your local agent, which talks to the YubiKey.

Setup
~~~~~

SSH's ``-R`` flag creates a remote Unix socket that forwards to a local one:

.. code-block:: sh

   # Get socket paths
   REMOTE_GPG_SOCK=$(ssh remote-host "gpgconf --list-dirs agent-socket")
   LOCAL_GPG_EXTRA=$(gpgconf --list-dirs agent-extra-socket)

   # Kill any existing remote agent -- critical!
   ssh remote-host "gpgconf --kill gpg-agent; rm -f ${REMOTE_GPG_SOCK}"

   # Connect with agent forwarding
   ssh -R "${REMOTE_GPG_SOCK}:${LOCAL_GPG_EXTRA}" remote-host \
       "pkg repo /path/to/repo/ signing_command: /path/to/sign-repo.sh"

The **extra socket** (``agent-extra-socket``) is a restricted socket that GPG
provides specifically for forwarding -- it limits operations to signing and
decryption, preventing a compromised remote from modifying your keyring.

The stale socket trap
~~~~~~~~~~~~~~~~~~~~~

If a ``gpg-agent`` is already running on
the remote (or a stale socket file exists), SSH's ``-R`` forwarding will fail
silently -- the remote socket file already exists, so SSH can't create its
forwarded socket. You'll get ``remote port forwarding failed for listen path``
in the SSH output, but the connection proceeds without forwarding. Then
``gpg-connect-agent`` on the remote talks to the local (remote machine's) agent
instead of your forwarded one, and signing fails because the key isn't there.

The fix: **always kill the remote gpg-agent and remove the socket in a separate
SSH call before the -R connection**:

.. code-block:: sh

   ssh remote-host "gpgconf --kill gpg-agent; rm -f ${REMOTE_GPG_SOCK}"
   ssh -R "${REMOTE_GPG_SOCK}:${LOCAL_GPG_EXTRA}" remote-host "..."

This must be two separate SSH calls. If you put the kill and the ``ssh -R`` in
the same command, the forwarding is set up at connection time -- before your
kill command runs.

PIN entry
~~~~~~~~~

When the signing operation reaches the YubiKey, it prompts for the user PIN via
``pinentry``. On macOS with ``pinentry-mac``, this is a GUI dialog on your
local machine. On Linux, ``pinentry-curses`` or ``pinentry-gnome3`` will prompt
on your local terminal or desktop. The remote machine never sees the PIN.

Putting it together: the build script
-------------------------------------

Here's the signing section of a build script that builds packages on a remote
FreeBSD host and signs the repo via agent forwarding:

.. code-block:: sh

   # Upload the signing script and public key
   scp -q tools/sign-repo.sh "${FIREWALL}:${REMOTE_REPO_DIR}/sign-repo.sh"
   scp -q Keys/repo.pub "${FIREWALL}:${REMOTE_REPO_DIR}/repo.pub"

   echo "Signing repo (GPG key on this host via agent forwarding)..."
   REMOTE_GPG_SOCK=$(ssh "${FIREWALL}" "gpgconf --list-dirs agent-socket")
   LOCAL_GPG_EXTRA=$(gpgconf --list-dirs agent-extra-socket)

   # Kill remote agent and remove stale socket before forwarding
   ssh "${FIREWALL}" "gpgconf --kill gpg-agent; rm -f ${REMOTE_GPG_SOCK}"

   # Sign with forwarded agent
   ssh -R "${REMOTE_GPG_SOCK}:${LOCAL_GPG_EXTRA}" "${FIREWALL}" \
       "pkg repo ${REMOTE_REPO_DIR}/ signing_command: ${REMOTE_REPO_DIR}/sign-repo.sh"

   # Verify signing succeeded (pkg repo exits 0 even on failure)
   ssh "${FIREWALL}" "test -f ${REMOTE_REPO_DIR}/meta.conf" || {
       echo "ERROR: Repo signing failed" >&2
       exit 1
   }

   # Clean up signing artifacts before downloading
   ssh "${FIREWALL}" "rm -f ${REMOTE_REPO_DIR}/sign-repo.sh ${REMOTE_REPO_DIR}/repo.pub"

Note the ``meta.conf`` check: ``pkg repo`` exits 0 even when signing fails, so
you need to verify the output explicitly.

Client-side setup
-----------------

On each machine that should trust the repo, install the fingerprint:

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
     - Signing command hangs forever
     - Use ``read -r`` -- pkg doesn't close stdin
   * - Fingerprint from DER key
     - "No trusted public keys found"
     - Fingerprint is ``SHA256(PEM file)``, headers and all
   * - Testing with ``openssl dgst -verify``
     - False negatives / false positives
     - This test is invalid for pkg signatures; use manual DigestInfo extraction
   * - Stale remote gpg-agent socket
     - "remote port forwarding failed"
     - Kill agent and remove socket in a *separate* SSH call before ``-R``
   * - ``pkg repo`` exit code
     - Build succeeds but repo is unsigned
     - Check for ``meta.conf`` existence after ``pkg repo``
   * - Using ``gpg --sign``
     - Produces OpenPGP format, not PKCS#1
     - Use ``gpg-connect-agent`` with ``PKSIGN`` for raw RSA
