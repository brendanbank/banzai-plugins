# banzai-plugins

OPNsense plugin collection. Each plugin lives in a `<category>/<plugin>/` subdirectory following the standard OPNsense plugin layout. Packages are served via a per-release GitHub Pages pkg repo.

## Plugins

| Plugin | Package | Description |
|--------|---------|-------------|
| `misc/hello_world` | `os-hello_world` | Hello World example plugin |

## Installation

### 1. Trust the repository signing key

All packages are signed. Before installing, set up the signing fingerprint on your firewall:

```sh
mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted
mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/revoked

cat > /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted/repo.fingerprint <<'EOF'
function: sha256
fingerprint: 5d03d774f3fa2926f9e2156b98d261461478f4f5d1332926fa5c7906b29eab87
EOF
```

You can verify the fingerprint matches the public key in [`Keys/repo.pub`](Keys/repo.pub) in this repository.

### 2. Add the repository

The repo URL includes the ABI (resolved by pkg) and OPNsense series:

```sh
SERIES=$(opnsense-version -a)

cat > /usr/local/etc/pkg/repos/banzai-plugins.conf <<EOF
banzai-plugins: {
  url: "https://brendanbank.github.io/banzai-plugins/\${ABI}/${SERIES}/repo",
  signature_type: "fingerprints",
  fingerprints: "/usr/local/etc/pkg/fingerprints/banzai-plugins",
  enabled: yes
}
EOF
pkg update -f -r banzai-plugins
```

`${ABI}` is a pkg built-in variable (e.g., `FreeBSD:14:amd64`) resolved at runtime. `${SERIES}` is the OPNsense series (e.g., `26.1`) detected from `opnsense-version -a`.

### 3. Install a plugin

```sh
pkg install os-hello_world
```

After installing the first plugin, the repo config is automatically maintained by the package hook scripts. Plugins also appear in **System > Firmware > Plugins** for UI-based management.

## Building

Build infrastructure comes from the `opnsense-plugins/` git submodule (pinned to a specific OPNsense release). First-time setup:

```sh
make setup    # initializes submodule and creates symlinks
```

Packages are built on a remote OPNsense/FreeBSD host via SSH:

```sh
./build.sh <firewall-hostname>
```

This detects the remote's ABI and OPNsense series, syncs all plugin directories, builds each with `make package`, downloads `.pkg` files to `dist/`, and updates the per-release GitHub Pages pkg repo in `docs/<ABI>/<series>/repo/`.

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source changes, tag `v<plugin>-<version>`, push with tags
5. Commit and push `docs/` to update GitHub Pages
6. Create GitHub Release with `.pkg` files attached

## License

BSD 2-Clause. See [LICENSE](LICENSE).
