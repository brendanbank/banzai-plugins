# kea-ddns Plugin — Feature Backlog

Prioritized by usefulness/impact. Each item includes current status and
the Kea configuration parameter(s) it maps to.

Completed items are tracked in [BACKLOG_COMPLETED.md](BACKLOG_COMPLETED.md).

---

## P1 — High Impact

### 1. Global DDNS defaults with per-subnet override

Add global-level fields for `qualifying-suffix`, `replace-client-name`,
`conflict-resolution`, `generated-prefix`, and other per-subnet options.
Subnets inherit the global value unless explicitly overridden. Reduces
repetitive configuration in multi-subnet deployments.

- **Effort:** Medium
- **Kea parameter:** All `ddns-`* parameters support global scope in Kea

---

## P2 — Medium Impact (Missing Kea Parameters)

### 2. ddns-override-no-update

Controls whether the server sends DDNS updates even when the client's
FQDN option requests no update. Important for environments where the
server must always control DNS records regardless of client preference.

- **Status:** Not implemented
- **Kea parameter:** `ddns-override-no-update` (boolean, default: false)
- **Scope:** Global, shared-network, subnet, pool, reservation

### 3. ddns-override-client-update

Controls whether the server overrides the client's request to perform
its own DNS update. When true, the server always performs forward updates
itself. Essential in managed environments where clients should not
directly update DNS.

- **Status:** Not implemented
- **Kea parameter:** `ddns-override-client-update` (boolean, default: false)
- **Scope:** Global, shared-network, subnet, pool, reservation

### 4. DNS TTL controls (ddns-ttl, ddns-ttl-percent, ddns-ttl-min, ddns-ttl-max)

Controls the TTL of DNS records created by DDNS updates. Currently uses
Kea defaults (derived from lease lifetime). Adding these gives operators
control over how long DNS records persist after a lease expires.

- **Status:** Not implemented
- **Kea parameters:**
  - `ddns-ttl` (uint32) — fixed TTL in seconds
  - `ddns-ttl-percent` (real, 0.0–1.0) — TTL as percentage of lease lifetime
  - `ddns-ttl-min` (uint32) — minimum TTL floor
  - `ddns-ttl-max` (uint32) — maximum TTL ceiling
- **Scope:** Global, shared-network, subnet, pool, reservation

### 5. dns-server-timeout (D2 daemon)

Maximum time in milliseconds the D2 daemon waits for a DNS server to
respond. The default (500ms) may be too short for remote or slow DNS
servers.

- **Status:** Hardcoded to Kea default (500ms)
- **Kea parameter:** `dns-server-timeout` (integer, ms, default: 500)
- **Scope:** D2 global

### 6. Multiple DNS servers per zone

Each forward/reverse zone currently supports only one DNS server. Kea D2
supports multiple servers per domain for redundancy (failover to the
next server if the first times out).

- **Status:** Single server per zone
- **Kea parameter:** `dns-servers` array in forward/reverse domains
- **Effort:** Medium (model + UI changes for repeatable server list)

### 7. TSIG digest-bits (truncated HMAC)

Allows specifying the minimum number of bits for truncated HMAC
signatures. Used in environments that require RFC 4635 compliant
truncated digests.

- **Status:** Not implemented
- **Kea parameter:** `digest-bits` (integer, default: 0 = full length)
- **Scope:** Per TSIG key

### 8. Configurable hostname sanitization

Hostname character filtering is hardcoded to `[^A-Za-z0-9.-]` → `-`.
Expose both the regex and the replacement character as configurable
fields.

- **Status:** Hardcoded in `getDhcpv4Overlay()` / `getDhcpv6Overlay()`
- **Kea parameters:**
  - `hostname-char-set` (string regex)
  - `hostname-char-replacement` (string)
- **Scope:** Global, shared-network, subnet, pool, reservation

---

## P3 — Lower Impact / Advanced

### 9. D2 listen address and port

The D2 daemon listen address is hardcoded to `127.0.0.1:53001`. In
split-daemon deployments (D2 on a different host), these need to be
configurable.

- **Status:** Hardcoded in `generateD2Config()` and overlay methods
- **Kea parameters:**
  - `ip-address` (string, default: 127.0.0.1)
  - `port` (integer, default: 53001)
- **Scope:** D2 global + dhcp-ddns section in DHCP configs

### 10. D2 logging level

D2 daemon log severity is hardcoded to `INFO`. Allow selecting from
DEBUG, INFO, WARN, ERROR for troubleshooting without manual config
editing.

- **Status:** Hardcoded to INFO
- **Kea parameter:** `severity` in D2 loggers (DEBUG/INFO/WARN/ERROR)
- **Scope:** D2 global

### 11. Per-server TSIG key override

Kea supports setting a different TSIG key per DNS server within a
domain, overriding the domain-level key. Useful when primary and
secondary DNS servers use different keys.

- **Status:** Not implemented (key is set at zone level only)
- **Kea parameter:** `key-name` on individual `dns-servers` entries
- **Scope:** Per DNS server within a domain

### 12. TSIG secret-file support

Kea supports loading TSIG secrets from a file instead of inline Base64.
More secure for deployments that manage secrets via configuration
management tools.

- **Status:** Not implemented
- **Kea parameter:** `secret-file` (string, path) — alternative to `secret`
- **Scope:** Per TSIG key

### 13. DNS zone validation / test button

Before applying, query the configured DNS servers to verify they respond
(SOA query) and accept TSIG-authenticated updates. Surface errors in the
UI rather than requiring log analysis.

- **Effort:** Medium-High
- **Kea parameter:** N/A (UX improvement, requires DNS query from PHP)

### 14. Import/export TSIG keys

Support importing TSIG keys from BIND `named.conf` key statements or
Kea JSON format, and exporting in both formats for configuring the DNS
server side.

- **Effort:** Medium
- **Kea parameter:** N/A (UX improvement)

### 15. DDNS lease event log viewer

Dedicated log view filtered to DDNS update events (success/failure per
hostname), parsed from kea-dhcp-ddns syslog output. Helps operators see
which names are being registered and spot failures.

- **Effort:** Medium
- **Kea parameter:** N/A (UX improvement)

### 16. Subnet DDNS bulk assignment

Allow assigning the same DDNS policy to multiple subnets at once instead
of configuring one-by-one. Valuable for large deployments with dozens of
subnets sharing the same DDNS policy.

- **Effort:** Medium
- **Kea parameter:** N/A (UX improvement)

### 17. Setup wizard

A guided workflow: create TSIG key → add forward zone → add reverse zone
→ assign to subnets. Reduces the multi-tab setup for first-time users.

- **Effort:** High
- **Kea parameter:** N/A (UX improvement)

### 18. GSS-TSIG / Kerberos support

Kea 2.4+ supports GSS-TSIG for Active Directory DNS integration via a
hook library. Would require Kerberos keytab management and hook library
configuration. High complexity but valuable for Windows/AD environments.

- **Effort:** Very High
- **Kea parameter:** GSS-TSIG hook library configuration
- **Dependency:** Kea GSS-TSIG hook library must be available on the system

---

## Coverage Matrix

### DHCP-side DDNS parameters (kea-dhcp4.conf / kea-dhcp6.conf)


| Parameter                       | Plugin    | Scope      |
| ------------------------------- | --------- | ---------- |
| `ddns-send-updates`             | Yes       | Per-subnet |
| `ddns-update-on-renew`          | Yes       | Per-subnet |
| `ddns-qualifying-suffix`        | Yes       | Per-subnet |
| `ddns-generated-prefix`         | Yes       | Per-subnet |
| `ddns-replace-client-name`      | Yes       | Per-subnet |
| `ddns-conflict-resolution-mode` | Yes       | Per-subnet |
| `ddns-override-no-update`       | **No**    | —          |
| `ddns-override-client-update`   | **No**    | —          |
| `ddns-ttl`                      | **No**    | —          |
| `ddns-ttl-percent`              | **No**    | —          |
| `ddns-ttl-min`                  | **No**    | —          |
| `ddns-ttl-max`                  | **No**    | —          |
| `hostname-char-set`             | Hardcoded | —          |
| `hostname-char-replacement`     | Hardcoded | —          |
| `dhcp-ddns.enable-updates`      | Yes       | Global     |
| `dhcp-ddns.server-ip`           | Hardcoded | —          |
| `dhcp-ddns.server-port`         | Hardcoded | —          |
| `rapid-commit` (v6 only)        | Yes       | Per-subnet |


### D2 daemon parameters (kea-dhcp-ddns.conf)


| Parameter                                 | Plugin                | Notes                      |
| ----------------------------------------- | --------------------- | -------------------------- |
| `ip-address`                              | Hardcoded (127.0.0.1) | —                          |
| `port`                                    | Hardcoded (53001)     | —                          |
| `dns-server-timeout`                      | **No**                | Default 500ms              |
| `ncr-protocol`                            | Hardcoded (UDP)       | Only UDP supported by Kea  |
| `ncr-format`                              | Hardcoded (JSON)      | Only JSON supported by Kea |
| `tsig-keys[].name`                        | Yes                   | —                          |
| `tsig-keys[].algorithm`                   | Yes                   | —                          |
| `tsig-keys[].secret`                      | Yes                   | —                          |
| `tsig-keys[].digest-bits`                 | **No**                | —                          |
| `tsig-keys[].secret-file`                 | **No**                | —                          |
| `forward-ddns.ddns-domains[].name`        | Yes                   | —                          |
| `forward-ddns.ddns-domains[].key-name`    | Yes                   | —                          |
| `forward-ddns.ddns-domains[].dns-servers` | Yes (single)          | Multiple not supported     |
| `reverse-ddns.ddns-domains[].name`        | Yes                   | —                          |
| `reverse-ddns.ddns-domains[].key-name`    | Yes                   | —                          |
| `reverse-ddns.ddns-domains[].dns-servers` | Yes (single)          | Multiple not supported     |
| `dns-servers[].key-name` (per-server)     | **No**                | —                          |
| `control-socket`                          | Hardcoded (unix)      | —                          |
| `loggers[].severity`                      | Hardcoded (INFO)      | —                          |


