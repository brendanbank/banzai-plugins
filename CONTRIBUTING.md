# Contributing to banzai-plugins

Suggestions and contributions are very welcome! There are several ways to contribute:

- **Report a bug or request a feature** — [open an issue](https://github.com/brendanbank/banzai-plugins/issues)
- **Submit a fix or improvement** — [open a pull request](https://github.com/brendanbank/banzai-plugins/pulls)
- **Contribute a new plugin** — see the guide below

## Prerequisites

- An OPNsense or FreeBSD host accessible via SSH (for building packages)
- Git with submodule support
- For maintainers: YubiKey with PIV and `yubico-piv-tool` for package repo signing (see below)

## Getting Started

```sh
git clone --recurse-submodules git@github.com:brendanbank/banzai-plugins.git
cd banzai-plugins
make setup
```

`make setup` initializes the `opnsense-plugins/` submodule and creates the symlinks (`Mk/`, `Keywords/`, `Templates/`, `Scripts/`) needed by the build system.

## Creating a New Plugin

1. Create the plugin directory structure:

    ```
    <category>/<plugin>/
    ├── Makefile
    ├── pkg-descr
    ├── +POST_INSTALL.post
    ├── +PRE_DEINSTALL.pre
    └── src/
    ```

2. Use `misc/hello_world/` as a reference for the required files.

3. The `Makefile` must define at minimum:

    ```makefile
    PLUGIN_NAME=        <plugin_name>
    PLUGIN_VERSION=     1.0
    PLUGIN_COMMENT=     Short description
    PLUGIN_MAINTAINER=  your@email.com

    .include "../../Mk/plugins.mk"
    ```

4. Package names are automatically prefixed with `os-` (e.g., `os-<plugin_name>`).

### Hook Scripts

Every plugin should include hook scripts based on the templates in `misc/hello_world/`:

- **`+POST_INSTALL.post`** — Registers the plugin with OPNsense firmware and adds the shared `banzai-plugins` pkg repo config (with per-release URL detection).
- **`+PRE_DEINSTALL.pre`** — Deregisters the plugin from OPNsense firmware.

Replace `hello_world` with your plugin name in both scripts.

### Plugin Source Layout

Follow the standard OPNsense MVC structure under `src/`:

- `etc/inc/plugins.inc.d/<plugin>.inc` — Plugin hook functions
- `opnsense/mvc/app/controllers/OPNsense/<Plugin>/` — Controllers (API + UI)
- `opnsense/mvc/app/models/OPNsense/<Plugin>/` — Models, ACL, Menu
- `opnsense/mvc/app/views/OPNsense/<Plugin>/` — Volt templates

### Conventions

- Add a BSD 2-Clause license header to all PHP and `.inc` files
- Model fields go at the root of `<items>` in model XML (no wrapper element)
- Don't set empty `<Default></Default>` or `<Required>N</Required>` — they're implicit
- `$internalModelName` in API controllers must match the `<id>` prefix in `forms/*.xml`

## Building

Packages are cross-built on a remote OPNsense/FreeBSD host via SSH:

```sh
./build.sh <firewall-hostname>
```

This will:

1. Detect the remote's ABI (e.g., `FreeBSD:14:amd64`) and OPNsense series (e.g., `26.1`)
2. Sync build infrastructure and plugin source to the remote
3. Build each plugin with `make package`
4. Download `.pkg` files to `dist/`
5. Sign and update the per-release pkg repo in `docs/<ABI>/<series>/repo/`

## Signing (maintainers)

Repo signing uses a key on your **YubiKey PIV** so the private key never leaves the device. During signing, the remote `sign.sh` writes the hash to a file and waits; `build.sh` polls for it over the existing SSH connection, signs locally with `tools/sign-repo.sh`, and writes the response back. No reverse tunnel or sshd on your laptop is needed.

**Setup:**

1. Install `yubico-piv-tool` (e.g. `brew install yubico-piv-tool`).
2. Put the repo signing key in PIV slot 9c (Digital Signature), or set `YUBICO_PIV_SLOT`. `Keys/repo.pub` must match that key.
3. For non-interactive builds, set `PIV_PIN` in the environment (otherwise you'll be prompted).
4. For a 4096-bit RSA key in PIV, set `YUBICO_PIV_ALG=RSA4096` (default is RSA2048).

**If migrating from 1Password:** Generate a new key in PIV (slot 9c, RSA2048), export its public key to `Keys/repo.pub`, update the fingerprint in `README.md` and in `docs/sphinx` (trusted fingerprint), then re-run the build.

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update the changelog in `<category>/<plugin>/pkg-descr`
3. Build: `./build.sh <firewall>`
4. Commit source changes, tag `v<version>`, push with tags
5. Commit and push `docs/` to update GitHub Pages
6. Create a GitHub Release: `gh release create v<version> dist/<pkg>.pkg`

## Updating Build Infrastructure

The build system comes from the `opnsense-plugins/` git submodule. To update it for a new OPNsense release:

```sh
git -C opnsense-plugins checkout <new-tag>
git add opnsense-plugins
git commit -m "Update opnsense-plugins submodule to <new-tag>"
```

## Code Style

Run linters before submitting:

```sh
make lint
make style
```

These require the symlinks from `make setup` to be in place.

## License

All contributions are under the BSD 2-Clause license. See [LICENSE](LICENSE).
