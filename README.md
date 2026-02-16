# banzai-plugins

Over the last four years of running OPNsense I've built various scripts and tools to manage and monitor my firewalls and the networks they serve. With each new release I do a clean install to avoid maintenance issues, which meant reinstalling all of these tools by hand every time.

Some of them have become essential to my workflow. The Prometheus metrics exporter, for example, feeds dpinger output into Prometheus and on to Grafana alerting, giving me visibility into my VPN overlay network so I know the moment something breaks.

This repository collects those tools and packages them as proper OPNsense plugins so they survive upgrades. Packages are signed and served from a per-release pkg repository via GitHub Pages, so installation is just a `pkg install` or a click in the Firmware UI.

**Why a separate repo?** These plugins sometimes involve a fair amount of code that would be difficult for the OPNsense team to validate and maintain, especially when adoption is likely to be limited. The OPNsense developers are focused on building a great product and shouldn't be distracted by niche tools that serve a small audience. This is not criticism -- it's simply the reality that you can't do it all. If a plugin here matures to the point where it belongs in the official [opnsense/plugins](https://github.com/opnsense/plugins) repository, great -- it will follow the standards and requirements set by the OPNsense project. Until then, contributions are welcome here.

I'm an [amateur](https://winningmindtraining.com/remaining-an-amateur-a-lover-of-the-work/) Python developer -- a lover of the work rather than a professional software engineer. I do have a long history with FreeBSD from my days as a sysadmin (DevOps before it had a name), when I built and ran products like imap4all.com. These plugins lean heavily on LLM-assisted development -- particularly [Claude Code](https://claude.ai/claude-code) -- for the MVC boilerplate, build infrastructure, and FreeBSD packaging. The code works, but it may not always follow every OPNsense convention to the letter. Suggestions and contributions are very welcome -- feel free to open an issue or pull request.

> **Warning:** These plugins are provided as-is. **Use at your own risk.**

Full documentation: [brendanbank.github.io/banzai-plugins](https://brendanbank.github.io/banzai-plugins/)

## Plugins

| Plugin | Package | Description |
|--------|---------|-------------|
| `misc/hello_world` | `os-hello_world` | Hello World example plugin |
| `sysutils/metrics_exporter` | `os-metrics_exporter` | Prometheus exporter for OPNsense metrics |

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

The repo URL includes the ABI (resolved by pkg at runtime) and OPNsense series:

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

- `${ABI}` is a pkg built-in variable (e.g., `FreeBSD:14:amd64`) resolved at runtime
- `${SERIES}` is the OPNsense series (e.g., `26.1`) from `opnsense-version -a`

### 3. Install a plugin

```sh
pkg install os-hello_world
```

After installing the first plugin, the repo config is automatically maintained by the package hook scripts. Plugins also appear in **System > Firmware > Plugins** for UI-based management.

## Repository Structure

```
banzai-plugins/
├── build.sh                    # Build, sign, and deploy script
├── Makefile                    # Root makefile (setup, list, lint, clean)
├── opnsense-plugins/           # Git submodule (opnsense/plugins, pinned)
├── Mk -> opnsense-plugins/Mk  # Symlinks created by `make setup`
├── Keywords -> ...             #
├── Templates -> ...            #
├── Scripts -> ...              #
├── Keys/                       # Signing public key + fingerprint
├── docs/                       # GitHub Pages (per-release pkg repos)
│   └── FreeBSD:14:amd64/
│       └── 26.1/
│           └── repo/           # Signed pkg repo for this ABI + series
├── dist/                       # Local build artifacts (gitignored)
└── <category>/<plugin>/        # Plugin directories
```

## Building

Build infrastructure comes from the [`opnsense-plugins/`](https://github.com/opnsense/plugins) git submodule, pinned to a specific OPNsense release tag. First-time setup:

```sh
git clone --recurse-submodules git@github.com:brendanbank/banzai-plugins.git
cd banzai-plugins
make setup    # creates symlinks for Mk/, Keywords/, Templates/, Scripts/
```

Packages are built on a remote OPNsense/FreeBSD host via SSH:

```sh
./build.sh <firewall-hostname>
```

This detects the remote's ABI and OPNsense series, syncs all plugin source and build infrastructure, builds each plugin with `make package`, downloads `.pkg` files to `dist/`, and updates the signed per-release pkg repo in `docs/`.

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source changes, tag `v<version>`, push with tags
5. Commit and push `docs/` to update GitHub Pages
6. Create GitHub Release with `.pkg` files attached

## Updating Build Infrastructure

The `opnsense-plugins/` submodule can be updated to track new OPNsense releases:

```sh
git -C opnsense-plugins checkout <new-tag>
git add opnsense-plugins
git commit -m "Update opnsense-plugins submodule to <new-tag>"
```

Multiple OPNsense series can coexist in `docs/` — each series gets its own repo directory.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD 2-Clause. See [LICENSE](LICENSE).
