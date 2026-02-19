# YubiKey PIV Signing for pkg Repos

How banzai-plugins signs FreeBSD pkg repositories using the YubiKey's PIV
applet via PKCS#11.

## Architecture

```
┌──────────────────────┐         ssh -R (unix socket)         ┌──────────────────────┐
│  Local workstation   │ ──────────────────────────────────── │  Remote build host   │
│                      │                                      │  (FreeBSD/OPNsense)  │
│  piv-sign-agent.py   │  ← forwarded socket ←                │  sign-repo.py        │
│  (PKCS#11 → YubiKey) │                                      │  (called by pkg repo)│
└──────────────────────┘                                      └──────────────────────┘
```

- **piv-sign-agent.py** runs on the local Mac, talks to the YubiKey PIV slot
  via PKCS#11 (`libykcs11.dylib`), listens on a Unix socket.
- **sign-repo.py** runs on the remote FreeBSD host, called by `pkg repo` as
  the `signing_command`. Connects to the forwarded Unix socket.
- **build.sh** uses `ssh -R` to forward the local agent socket to the remote.
- SSH authentication is unchanged — gpg-agent with `--enable-ssh-support`
  handles auth directly (no `-A` forwarding needed for the build host).

## PIV vs GPG

The previous approach used the GPG applet with `gpg-connect-agent` and Assuan
protocol over a forwarded gpg-agent socket. Problems:

- gpg-agent socket forwarding is fragile (stale sockets, must kill remote
  agent first in a separate SSH call)
- Assuan protocol is complex (percent-encoded D lines, S-expression parsing)
- gpg-agent socket conflicts with SSH auth when both use the same agent

PIV advantages:

- Independent applet — no contention with GPG/SSH auth
- PKCS#11 is a standard interface — no proprietary protocol
- Simple custom socket protocol — no Assuan/S-expression complexity
- Socket forwarding is straightforward (just a file, no running agent to kill)

## PIV Slot Configuration

The signing key lives in PIV slot **9c** (Digital Signature).

```
$ ykman piv info
Slot 9C (SIGNATURE):
  Private key type: RSA2048
  Public key type:  RSA2048
  Subject DN:       CN=banzai-plugins repo signing
  PIN required:     ALWAYS
  Touch required:   ALWAYS
```

- **RSA 2048** — YubiKey 5.4 PIV supports up to RSA 2048 (GPG applet
  supports 4096, but PIV does not).
- **PIN required: ALWAYS** — every signing operation requires the PIV PIN.
- **Touch required: ALWAYS** — every signing operation requires physical
  touch of the YubiKey. The key blinks when waiting. If not touched within
  ~15 seconds, the operation fails with PKCS#11 error 0x101.

## PKCS#11 Signing with ctypes

The signing daemon uses Python ctypes to call `libykcs11.dylib` directly.
No external dependencies (`pkcs11-tool`, `opensc`, pip packages) required
beyond what Homebrew's `yubico-piv-tool` provides.

### Library location

```
/opt/homebrew/lib/libykcs11.dylib    # macOS (Homebrew)
/usr/lib/libykcs11.so                # Linux
```

### PKCS#11 flow

```python
C_Initialize(None)
C_GetSlotList(tokenPresent=True) → slot
C_OpenSession(slot, CKF_SERIAL_SESSION | CKF_RW_SESSION) → session
C_Login(session, CKU_USER, pin)
C_FindObjectsInit(session, [CKA_CLASS=CKO_PRIVATE_KEY, CKA_SIGN=True])
C_FindObjects(session) → key_handle
C_FindObjectsFinal(session)

# For each signing request:
C_SignInit(session, CKM_RSA_PKCS, key_handle)
C_Sign(session, digest_info, sig_buf) → signature    # touch required here
```

### DigestInfo construction

`CKM_RSA_PKCS` performs raw PKCS#1 v1.5 padding — the caller must provide
the DER-encoded DigestInfo structure:

```python
SHA256_DER_PREFIX = bytes([
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20
])
digest_info = SHA256_DER_PREFIX + sha256_hash  # 19 + 32 = 51 bytes
```

### Touch timeout

When touch is required, `C_Sign` blocks until the user touches the YubiKey.
If not touched within ~15 seconds, it returns error **0x101**
(`CKR_CANCEL` in Yubico's PKCS#11 implementation). The daemon should:

- Print a message to stderr when waiting for touch
- Use a reasonable timeout (30 seconds)
- Return a clear error if touch times out

### PIN handling

The PIV PIN is stored in 1Password under the item "banzai-plugins pkg repo
signing key", field "pin". Retrieved at daemon startup:

```sh
op item get "banzai-plugins pkg repo signing key" --fields pin --reveal
```

The daemon accepts the PIN via:
1. `PIV_PIN` environment variable (highest priority)
2. Interactive prompt at startup (fallback)

The PIN is 8 characters. The YubiKey locks after 3 failed attempts.

## pkg Signing Protocol

Documented in detail in `docs/sphinx/articles/yubikey-pkg-signing.rst`.
Quick summary:

### What pkg sends

`pkg repo` pipes `SHA256(catalogue_data)` as a **64-char lowercase hex
string** to the signing command's stdin. It does **not** close stdin — the
signing command must use `readline()`, not `read()`.

### Double hash

pkg verifies signatures against `SHA256(hex_string)`, not the hex string
directly. The signing command must:

1. Read the hex string from stdin
2. Compute `SHA256(hex_string_bytes)` → 32-byte digest
3. Sign that digest (with PKCS#1 v1.5 DigestInfo wrapping)

### Expected output format

```
SIGNATURE
<raw binary RSA signature bytes>
CERT
<PEM public key>
END
```

### Fingerprint

Clients verify using `SHA256(PEM file)` — the entire file including
`-----BEGIN/END-----` headers and trailing newline.

## Agent Protocol

The PIV signing daemon uses a simple line-based protocol over a Unix socket:

### Requests

```
SIGN SHA256 <hex-encoded-32-byte-digest>\n
PUBKEY\n
```

### Responses

```
OK <base64-encoded-data>\n
ERR <message>\n
```

For `SIGN`: the base64 data is the raw PKCS#1 v1.5 RSA signature.
For `PUBKEY`: the base64 data is the PEM public key.

## Key Rotation

Switching from GPG (RSA 4096) to PIV (RSA 2048) requires:

1. Export the PIV public key: `ykman piv keys export 9c Keys/repo.pub`
2. Update `Keys/fingerprint` with `SHA256(Keys/repo.pub)`
3. Update release docs fingerprint
4. Update fingerprints on all clients (casa, fw):
   `/usr/local/etc/pkg/fingerprints/banzai-plugins/trusted/repo.fingerprint`

## Verified Behavior

Tested on 2026-02-19:

- PKCS#11 session via `libykcs11.dylib` — works
- `C_Login` with PIV PIN from 1Password — works (2 retries remaining after
  one failed attempt with wrong PIN)
- `C_Sign` with `CKM_RSA_PKCS` + DigestInfo — works (requires touch)
- Signature verified: `openssl rsautl -verify` recovers the correct
  double-hash `SHA256(hex_string)`
- PIV public key extracted via `ykman piv keys export 9c` matches the key
  used for verification
