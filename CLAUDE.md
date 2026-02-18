# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Multi-plugin OPNsense repo modeled after `opnsense/plugins`. Each plugin is a `<category>/<plugin>/` subdirectory with the standard OPNsense plugin layout. Packages are signed and served via a per-release GitHub Pages pkg repo at `https://brendanbank.github.io/banzai-plugins/${ABI}/<series>/repo`.

Build infrastructure (`Mk/`, `Keywords/`, `Templates/`, `Scripts/`) comes from the `opnsense-plugins/` git submodule (pinned to a specific OPNsense release tag). Run `make setup` to initialize the submodule and create symlinks.

## Firewalls

SSH connects as an unprivileged user (not root). Use `sudo` for privileged commands (`pkg`, `configctl`, reading config.xml).

## Build and Deploy

```sh
make setup                          # first time: init submodule + create symlinks
./build.sh <firewall-hostname>      # build all plugins, download pkgs, update repo
```

`build.sh` detects the remote's ABI (`FreeBSD:14:amd64`) and OPNsense series (`26.1`), syncs build infrastructure from the submodule (with an empty `devel.mk` override to prevent `-devel` suffix), builds each plugin, and populates `docs/<ABI>/<series>/repo/`.

After building, commit and push `docs/` to update the GitHub Pages pkg repo. Plugins are installable via the OPNsense UI at **System > Firmware > Plugins** or via `pkg install`.

## Repo Versioning

The repo itself is tagged with semver-style versions:

- **Major** — repo infrastructure changes (build system, signing, submodule updates)
- **Minor** — new plugins added
- **Patch** — plugin version bumps

Individual plugins have their own `PLUGIN_VERSION` in their Makefile.

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source + docs changes, tag `v<version>`, push with tags
5. `gh release create v<version> dist/*.pkg`

## Adding a New Plugin

1. Create `<category>/<plugin>/` with standard layout (Makefile, pkg-descr, src/, hook scripts)
2. Copy hook scripts from `misc/hello_world/` as a starting point
3. Replace `hello_world` references with new plugin name in hook scripts
4. Set `PLUGIN_WWW` to the plugin's documentation page: `https://brendanbank.github.io/banzai-plugins/releases/<series>/<plugin>.html`
5. `+POST_INSTALL.post` detects the OPNsense series and writes a per-release repo URL
6. Add the plugin to the table in README.md

## Key Conventions

- BSD 2-Clause license header in all PHP/inc files
- Package names: `os-<plugin_name>` (OPNsense requires `os-` prefix)
- `+POST_INSTALL.post` registers plugin with firmware + adds shared banzai-plugins repo config
- `+PRE_DEINSTALL.pre` deregisters plugin from firmware (repo config is left in place)
- Model XML: don't set empty `<Default></Default>` or `<Required>N</Required>` — they're implicit
- `$internalModelName` in API controllers must match the `<id>` prefix in `forms/*.xml`
- Model fields go at root of `<items>` (no wrapper element)

## Build Server Tools (`tools/`)

Three scripts handle the OPNsense VM image build lifecycle:

- **`tools/create-build-vm.sh`** — runs locally on a KVM/libvirt host to
  create a FreeBSD build server VM. Self-contained, no SSH wrappers.
- **`tools/opnsense-build.sh`** — workstation-side orchestrator that operates
  on the build server via SSH.
- **`tools/opnsense-build-server.sh`** — runs directly on the build server for
  local builds. Synced to `/usr/local/bin/` by `opnsense-build.sh bootstrap`.

```sh
# On the KVM host: create a build VM
./tools/create-build-vm.sh create --ssh-pubkey ~/.ssh/id_ed25519.pub

# On your workstation: orchestrate remote builds
./tools/opnsense-build.sh bootstrap     # clone OPNsense repos, sync server script
./tools/opnsense-build.sh update        # pull latest code for all repos
./tools/opnsense-build.sh sync-device   # sync BANZAI.conf to build server
./tools/opnsense-build.sh build         # full VM image build (or: build base kernel ports ...)
./tools/opnsense-build.sh status        # show repo state, artifacts, disk/RAM
./tools/opnsense-build.sh deploy        # deploy image to KVM guest
./tools/opnsense-build.sh series 26.7   # switch repos to a new release series

# On the build server: run builds directly
opnsense-build-server.sh build          # full build
opnsense-build-server.sh build core vm  # rebuild specific stages
opnsense-build-server.sh status         # show local server state
opnsense-build-server.sh update         # pull latest repos
```

Configuration lives in `tools/opnsense-build.conf` (git-ignored, user-local).
Copy `opnsense-build.conf.sample` to get started. Key settings: `BUILD_HOST`
(SSH target), `SERIES` (release series), `KVM_HOST` (for deployment).

Shared helpers are in `tools/lib/common.sh` (SSH wrappers, logging, remote git
operations). All `/usr` repos on the build server are root-owned, so git/make
commands go through `sudo`.

## Plugin Layout

```
<category>/<plugin>/
├── Makefile                              # PLUGIN_NAME, PLUGIN_VERSION, etc.
├── pkg-descr                             # Description + changelog
├── +POST_INSTALL.post                    # Register plugin, add repo config
├── +PRE_DEINSTALL.pre                    # Deregister plugin
└── src/
    ├── etc/inc/plugins.inc.d/<plugin>.inc  # Plugin hooks
    └── opnsense/mvc/app/
        ├── controllers/OPNsense/<Plugin>/
        │   ├── Api/                      # REST API endpoints
        │   ├── forms/                    # Form XML definitions
        │   └── GeneralController.php     # UI controller
        ├── models/OPNsense/<Plugin>/
        │   ├── <Plugin>.xml              # Model structure
        │   ├── <Plugin>.php              # Model logic
        │   ├── ACL/ACL.xml               # Access control
        │   └── Menu/Menu.xml             # Menu registration
        └── views/OPNsense/<Plugin>/
            └── general.volt              # UI template
```
