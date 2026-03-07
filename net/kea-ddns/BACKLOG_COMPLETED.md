# kea-ddns Plugin — Completed Backlog Items

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
