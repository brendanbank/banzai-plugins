# banzai-plugins

OPNsense plugin collection. Each plugin lives in a `<category>/<plugin>/` subdirectory following the standard OPNsense plugin layout. Packages are served via a shared GitHub Pages pkg repo.

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
fingerprint: c7d009bc3d9bd80d4327a8b9a9eb7884ac5411c24d0163a2b551479aa1710ec1
EOF
```

You can verify the fingerprint matches the public key in [`Keys/repo.pub`](Keys/repo.pub) in this repository.

### 2. Add the repository

```sh
cat > /usr/local/etc/pkg/repos/banzai-plugins.conf <<'EOF'
banzai-plugins: {
  url: "https://brendanbank.github.io/banzai-plugins/repo",
  signature_type: "fingerprints",
  fingerprints: "/usr/local/etc/pkg/fingerprints/banzai-plugins",
  enabled: yes
}
EOF
pkg update -f -r banzai-plugins
```

### 3. Install a plugin

```sh
pkg install os-hello_world
```

After installing the first plugin, the repo config is automatically maintained by the package hook scripts. Plugins also appear in **System > Firmware > Plugins** for UI-based management.

## Building

Packages are built on a remote OPNsense/FreeBSD host via SSH:

```sh
./Scripts/build.sh <firewall-hostname>
```

This syncs all plugin directories, builds each with `make package`, downloads `.pkg` files to `dist/`, and updates the GitHub Pages pkg repo in `docs/repo/`.

Build infrastructure (`Mk/`, `Keywords/`, `Templates/`, `Scripts/`) is included in the repo (copied from `opnsense/plugins`).

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./Scripts/build.sh <firewall>`
4. Commit source changes, tag `v<plugin>-<version>`, push with tags
5. Commit and push `docs/repo/`
6. Create GitHub Release with `.pkg` files attached

## License

BSD 2-Clause. See [LICENSE](LICENSE).
