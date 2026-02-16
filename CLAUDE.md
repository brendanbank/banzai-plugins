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

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source changes, tag `v<version>`, push with tags
5. Commit and push `docs/` to update GitHub Pages
6. `gh release create v<version> dist/<pkg>.pkg`

## Adding a New Plugin

1. Create `<category>/<plugin>/` with standard layout (Makefile, pkg-descr, src/, hook scripts)
2. Copy hook scripts from `misc/hello_world/` as a starting point
3. Replace `hello_world` references with new plugin name in hook scripts
4. `+POST_INSTALL.post` detects the OPNsense series and writes a per-release repo URL
5. Add the plugin to the table in README.md

## Key Conventions

- BSD 2-Clause license header in all PHP/inc files
- Package names: `os-<plugin_name>` (OPNsense requires `os-` prefix)
- `+POST_INSTALL.post` registers plugin with firmware + adds shared banzai-plugins repo config
- `+PRE_DEINSTALL.pre` deregisters plugin from firmware (repo config is left in place)
- Model XML: don't set empty `<Default></Default>` or `<Required>N</Required>` — they're implicit
- `$internalModelName` in API controllers must match the `<id>` prefix in `forms/*.xml`
- Model fields go at root of `<items>` (no wrapper element)

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
