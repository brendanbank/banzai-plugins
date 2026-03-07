# kea-ddns Plugin — Completed Backlog Items

---

## P1 — High Impact

### 1. TSIG key auto-generation

A **Generate** button in the TSIG key dialog creates a cryptographically
random Base64 secret of the correct length for the selected algorithm.
Eliminates the need to run `tsig-keygen` or `dnssec-keygen` externally.

**Implementation:**
- `generateTsigSecretAction()` in `Api/GeneralController.php` — POST
  endpoint accepts `algorithm` parameter, returns `{secret: "<base64>"}`.
- Key lengths: MD5=16, SHA1=20, SHA224=28, SHA256=32, SHA384=48, SHA512=64.
- UI: button injected next to the secret field in the TSIG key dialog
  (`general.volt`), reads the selected algorithm from the dropdown.

### 2. Per-subnet reverse zone auto-mapping

Auto-derive `in-addr.arpa` / `ip6.arpa` zone names from configured Kea
subnet CIDRs. A dropdown in the reverse zone dialog lists all DHCPv4 and
DHCPv6 subnets with their corresponding reverse zone names.

**Implementation:**
- `suggestReverseZonesAction()` in `Api/GeneralController.php` — reads
  `KeaDhcpv4` and `KeaDhcpv6` model subnets, returns suggestions with
  subnet, zone name, and address family.
- `deriveIpv4ReverseZone()` — octet-boundary rounding (`ceil(prefix/8)`),
  reverse up to 3 significant octets.
- `deriveIpv6ReverseZone()` — nibble-boundary rounding (`ceil(prefix/4)`),
  expand with `inet_pton`, reverse nibbles.
- UI: subnet picker dropdown + **Derive** button in reverse zone dialog
  (`general.volt`). Double-click also populates the zone name field.

### 3. DDNS status dashboard

Separate Status page querying the D2 control socket for daemon status,
update statistics, per-TSIG-key counters, and per-lease DDNS info.

**Implementation:**
- `ddns_status.py` — Python configd script querying D2 Unix socket
  (`/var/run/kea/kea-ddns-ctrl-socket`) with `status-get`, `version-get`,
  and `statistic-get-all` commands.
- `actions_kea_ddns.conf` — configd action definition.
- `ddnsStatusAction()` — calls configd, returns daemon info + statistics.
- `searchDdnsLeasesAction()` — fetches leases from core Kea via
  `configdpRun`, filters for `fqdn_fwd`/`fqdn_rev`, returns paginated
  results via `searchRecordsetBase()`.
- `status.volt` — two-tab page: Daemon Status (version, PID, uptime,
  global stats, per-key stats) and DDNS Leases (paginated `UIBootgrid`
  with forward/reverse checkmarks and expiry timestamps).
- `Menu.xml` — Status menu item at order 20.
- `GeneralController.php` (UI) — `statusAction()` routing.

---

## P0 — Infrastructure (repo-wide, not kea-ddns specific)

### 0. Dev branch plugin install via the OPNsense firmware UI

Allow installing development builds from a branch through the standard
OPNsense **System > Firmware > Plugins** UI.

**Implementation:**

Uses the existing opnsense-plugins `PLUGIN_DEVEL` / conflicts machinery.

1. **`build.sh --dev`** — Creates `devel.mk` with `PLUGIN_DEVEL?=yes` so
   packages are built as `os-<name>-devel` (with `PLUGIN_TIER=4`,
   conflicts with stable). Published to a separate GitHub Pages path:
   `docs/<ABI>/<series>/dev/repo/` (signed with the same key).

2. **Dev repo config** — All `+POST_INSTALL.post` scripts write a
   disabled `banzai-plugins-dev.conf` pointing to the dev repo path.

3. **Enable on the firewall:**
   ```sh
   sudo sed -i '' 's/enabled: no/enabled: yes/' \
     /usr/local/etc/pkg/repos/banzai-plugins-dev.conf
   sudo pkg update
   ```
   Then `os-<name>-devel` packages appear in **System > Firmware >
   Plugins**. Installing `-devel` automatically removes the stable
   version (pkg conflicts).

**Bugs found during implementation:**
- `devel.mk` doesn't exist in stable-branch submodules — `--dev` must
  create it with `PLUGIN_DEVEL?=yes` rather than just skipping the
  override.
- `metrics_exporter` had `${PLUGIN_PKGSUFFIX}` on its `os-node_exporter`
  dependency — external packages shouldn't get the `-devel` suffix.

**Future:** GitHub Actions CI to auto-build on branch push
