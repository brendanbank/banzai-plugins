# banzai-plugins

OPNsense plugin collection. Each plugin lives in a `<category>/<plugin>/` subdirectory following the standard OPNsense plugin layout. Packages are served via a shared GitHub Pages pkg repo.

## Plugins

| Plugin | Package | Description |
|--------|---------|-------------|
| `misc/hello_world` | `os-hello_world` | Hello World example plugin |

## Installation

On your OPNsense firewall, add the banzai-plugins pkg repo and install a plugin:

```sh
# Add the repo
cat > /usr/local/etc/pkg/repos/banzai-plugins.conf <<'EOF'
banzai-plugins: {
  url: "https://brendanbank.github.io/banzai-plugins/repo",
  enabled: yes
}
EOF
pkg update -f -r banzai-plugins

# Install a plugin
pkg install os-hello_world
```

After installing any plugin from this repo, the repo config is automatically maintained by the package hook scripts. Plugins appear in **System > Firmware > Plugins** for UI-based management.

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
