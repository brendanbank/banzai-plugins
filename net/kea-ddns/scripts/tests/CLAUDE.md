# kea-ddns Test Scripts

Two test suites for the kea-ddns plugin:

## On-Firewall Tests (`functional_test.sh`)

Runs directly on the OPNsense firewall via `sudo`. Validates the full DDNS
pipeline after the plugin is already installed and configured.

```sh
sudo sh scripts/functional_test.sh
```

**Test modules** (sourced by `functional_test.sh`):

| File | What it tests |
|------|--------------|
| `lib.sh` | Shared helpers (pass/fail, kea_command, preflight) |
| `test_config.sh` | Plugin hook, JSON configs, keactrl, DHCP4 params, zones |
| `test_runtime.sh` | Running daemons, control sockets, lease DDNS flags |
| `test_dns.sh` | Forward/reverse DNS lookups for existing leases |
| `test_ddns_roundtrip.sh` | Adds synthetic leases, triggers DDNS, verifies DNS, cleans up |

Requires: `jq`, `socat`, `dig`, `pgrep`, `nsupdate` on the firewall.

## Interaction Test (`ddns_interaction_test.sh`)

Runs from the **workstation** via OPNsense API + SSH. Tests how core DDNS
(PR #9923) and the kea-ddns plugin interact across five scenarios.

```sh
cd net/kea-ddns
./scripts/ddns_interaction_test.sh              # all phases
./scripts/ddns_interaction_test.sh 1 2          # specific phases
./scripts/ddns_interaction_test.sh --check      # connectivity check only
```

### Configuration

Copy `scripts/tests/interaction/ddns_interaction_test.conf.sample` to
`ddns_interaction_test.conf` (same directory, git-ignored) and fill in:

- `OPN_HOST` — firewall IP
- `OPN_SSH_USER` — SSH user (non-root uses sudo)
- `OPN_API_KEY_FILE` — path to file with `key:secret`
- `DDNS_ZONE`, `DDNS_NS`, `TSIG_KEY_*` — DNS test environment
- `TEST_SUBNET_PATTERN` — matches a Kea DHCPv4 subnet
- `PLUGIN_PKG` — package name (`os-kea-ddns` or `os-kea-ddns-devel`)
- `PLUGIN_PKG_FILE` — optional local `.pkg` for SCP install

### Phases

| Phase | Scenario | What it verifies |
|-------|----------|-----------------|
| 1 | Core DDNS only | PR #9923 works standalone (config, daemon, keactrl) |
| 2 | Plugin only | Plugin works with core DDNS disabled |
| 3 | Both enabled | Which config wins, duplicates, restart behavior |
| 4 | Core + disabled plugin | Plugin should be inert (known bug: overwrites keactrl) |
| 5 | Cleanup | Uninstall, orphan check, TSIG format, final reset |

### Known Issue (Phase 4)

When the plugin is installed but disabled and core DDNS is enabled, the
plugin's `kea_ddns_configure_do()` calls `kea_ddns_update_keactrl(false)`,
overwriting core's `dhcp_ddns=yes`. Fix: check whether core DDNS is active
before touching `keactrl.conf` when the plugin is disabled.

### Files

```
scripts/
├── ddns_interaction_test.sh          # Main entry point (workstation)
├── functional_test.sh                # On-firewall test
└── tests/
    ├── CLAUDE.md                     # This file
    ├── lib.sh                        # On-firewall helpers
    ├── test_config.sh                # On-firewall: config validation
    ├── test_runtime.sh               # On-firewall: daemon/lease checks
    ├── test_dns.sh                   # On-firewall: DNS lookups
    ├── test_ddns_roundtrip.sh        # On-firewall: end-to-end DDNS
    └── interaction/
        ├── opnapi.sh                 # API/SSH helpers for interaction test
        ├── ddns_interaction_test.conf.sample
        └── phases/
            ├── phase1_core_ddns.sh
            ├── phase2_plugin_only.sh
            ├── phase3_both_enabled.sh
            ├── phase4_plugin_disabled.sh
            └── phase5_cleanup.sh
```

### Requires

Workstation: `curl`, `jq`, `ssh`, `dig`
Firewall: Kea DHCPv4 enabled, SSH access, API key
