# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Multi-plugin OPNsense repo modeled after `opnsense/plugins`. Each plugin is a `<category>/<plugin>/` subdirectory with the standard OPNsense plugin layout. Packages are served via a per-release GitHub Pages pkg repo at `https://brendanbank.github.io/banzai-plugins/${ABI}/<series>/repo`.

Build infrastructure (`Mk/`, `Keywords/`, `Templates/`, `Scripts/`) comes from the `opnsense-plugins/` git submodule (pinned to a specific OPNsense release tag). Run `make setup` to initialize the submodule and create symlinks.

## Firewalls

SSH connects as an unprivileged user (not root). Use `sudo` for privileged commands (`pkg`, `configctl`, reading config.xml).

## Build and Deploy

```sh
make setup                          # first time: init submodule + create symlinks
./build.sh <firewall-hostname>      # build all plugins, download pkgs, update repo
```

`build.sh` detects the remote's ABI (`FreeBSD:14:amd64`) and OPNsense series (`26.1`), syncs build infrastructure from the submodule (with an empty `devel.mk` override to prevent `-devel` suffix), builds each plugin, and populates `docs/<ABI>/<series>/repo/`.

After building, commit and push `docs/` to update the GitHub Pages pkg repo. Plugins are installable via the OPNsense UI at **System > Firmware > Plugins**.

## Adding a New Plugin

1. Create `<category>/<plugin>/` with standard layout (Makefile, pkg-descr, src/, hook scripts)
2. Use `banzai-plugins` as the shared pkg repo name in hook scripts (not per-plugin repos)
3. Hook scripts register/deregister the plugin and manage the shared repo config
4. `+POST_INSTALL.post` detects the OPNsense series and writes a per-release repo URL
5. Add the plugin to the table in README.md

## Key Conventions

- BSD 2-Clause license header in all PHP/inc files
- `+POST_INSTALL.post` registers plugin + adds shared banzai-plugins pkg repo config with per-release URL
- `+PRE_DEINSTALL.pre` deregisters plugin from firmware (repo config is left in place)
- Model XML: don't set empty `<Default></Default>` or `<Required>N</Required>` — they're implicit
- `$internalModelName` in API controllers must match the `<id>` prefix in `forms/*.xml`
- Model fields go at root of `<items>` (no wrapper element)

## Plugin Layout

```
<category>/<plugin>/
├── Makefile
├── pkg-descr
├── +POST_INSTALL.post
├── +PRE_DEINSTALL.pre
└── src/
    ├── etc/inc/plugins.inc.d/<plugin>.inc
    └── opnsense/mvc/app/
        ├── controllers/OPNsense/<Plugin>/
        ├── models/OPNsense/<Plugin>/
        └── views/OPNsense/<Plugin>/
```
