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
./build.sh <firewall-hostname>      # build stable plugins, sign, update repo
./build.sh --dev <firewall-hostname> # build -devel plugins to dev repo
./build.sh --test <firewall-hostname> # build only, skip signing/docs
```

`build.sh` detects the remote's ABI (`FreeBSD:14:amd64`) and OPNsense series (`26.1`), syncs build infrastructure from the submodule, builds each plugin, and populates the signed pkg repo in `docs/`.

- **Stable builds** (default): empties `devel.mk` to produce `os-<name>` packages → `docs/<ABI>/<series>/repo/`
- **Dev builds** (`--dev`): creates `devel.mk` with `PLUGIN_DEVEL?=yes` to produce `os-<name>-devel` packages (TIER 4, conflicts with stable) → `docs/<ABI>/<series>/dev/repo/`

After building, commit and push `docs/` to update the GitHub Pages pkg repo. Plugins are installable via the OPNsense UI at **System > Firmware > Plugins** or via `pkg install`.

## Repo Versioning

The repo itself is tagged with semver-style versions:

- **Major** — repo infrastructure changes (build system, signing, submodule updates)
- **Minor** — new plugins added
- **Patch** — plugin version bumps

Individual plugins have their own `PLUGIN_VERSION` in their Makefile.

## Branch Model

Two long-lived branches serve the GitHub Pages pkg repos:

- **`main`** — source code and stable repo (`docs/<ABI>/<series>/repo/`)
- **`devel`** — dev repo overlay (`docs/<ABI>/<series>/dev/repo/`)

The GitHub Actions workflow (`publish-dev-repo.yml`) deploys Pages by copying
`main`'s `docs/` first, then overlaying `devel`'s `docs/.../dev/` on top. This
means **dev repo packages must be committed to the `devel` branch** for Pages
to serve them. If `devel` has stale packages, they overwrite newer ones from
`main`.

## Releasing

### Stable release

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source + docs changes, tag `v<version>`, push with tags
5. `gh release create v<version> dist/*.pkg`

### Dev release

1. Start the PIV signing agent: `python3 tools/piv-sign-agent.py`
2. `./build.sh --dev <firewall>` — builds `-devel` packages and updates
   `docs/<ABI>/<series>/dev/repo/`
3. Commit the dev repo changes to the **`devel`** branch (not `main`):
   ```sh
   git checkout devel
   git merge <your-branch>           # sync source changes first
   git add docs/<ABI>/<series>/dev/
   git commit -m "Update dev repo with <package> <version>"
   git push origin devel
   ```
4. The Pages workflow triggers on `devel` push and deploys the updated dev repo
5. On the firewall, enable the dev repo and install:
   ```sh
   sudo sed -i '' 's/enabled: no/enabled: yes/' \
     /usr/local/etc/pkg/repos/banzai-plugins-dev.conf
   sudo pkg update -r banzai-plugins-dev
   sudo pkg install -r banzai-plugins-dev os-<name>-devel
   ```

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
- `+POST_INSTALL.post` registers plugin with firmware + adds shared banzai-plugins repo config + disabled dev repo config
- `+PRE_DEINSTALL.pre` deregisters plugin from firmware (repo config is left in place)
- Model XML: don't set empty `<Default></Default>` or `<Required>N</Required>` — they're implicit
- `$internalModelName` in API controllers must match the `<id>` prefix in `forms/*.xml`
- Model fields go at root of `<items>` (no wrapper element)

## Build Server Tools

The OPNsense VM image build system lives in a separate repo:
[banzai-build](https://github.com/brendanbank/banzai-build). See its CLAUDE.md
for build, deploy, and VM creation instructions.

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
