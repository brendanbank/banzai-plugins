# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Multi-plugin OPNsense repo modeled after `opnsense/plugins`. Each plugin is a `<category>/<plugin>/` subdirectory with the standard OPNsense plugin layout. All plugins share a single GitHub Pages pkg repo at `https://brendanbank.github.io/banzai-plugins/repo`.

## Firewalls

SSH connects as an unprivileged user (not root). Use `sudo` for privileged commands (`pkg`, `configctl`, reading config.xml).

## Build and Deploy

```sh
./Scripts/build.sh <firewall-hostname>    # build all plugins, download pkgs, update repo
```

This syncs all `<category>/<plugin>/` directories and build infrastructure (`Mk/`, `Keywords/`, `Templates/`, `Scripts/`) to the remote, builds each plugin with `make package`, downloads `.pkg` files to `dist/`, and updates `docs/repo/`. Build infrastructure is included in the repo (copied from `opnsense/plugins`).

After building, commit and push `docs/repo/` to update the GitHub Pages pkg repo. Plugins are installable via the OPNsense UI at **System > Firmware > Plugins**.

## Adding a New Plugin

1. Create `<category>/<plugin>/` with standard layout (Makefile, pkg-descr, src/, hook scripts)
2. Use `banzai-plugins` as the shared pkg repo name in hook scripts (not per-plugin repos)
3. Hook scripts register/deregister the plugin and manage the shared repo config
4. Add the plugin to the table in README.md

## Key Conventions

- BSD 2-Clause license header in all PHP/inc files
- `+POST_INSTALL.post` registers plugin + adds shared banzai-plugins pkg repo config
- `+PRE_DEINSTALL.pre` deregisters plugin (only removes repo config if no other banzai plugins remain)
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
