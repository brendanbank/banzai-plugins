# banzai-plugins

Over the last four years of running OPNsense I've built various scripts and tools to manage and monitor my firewalls and the networks they serve. With each new release I do a clean install to avoid maintenance issues, which meant reinstalling all of these tools by hand every time.

Some of them have become essential to my workflow. The Prometheus metrics exporter, for example, feeds dpinger output into Prometheus and on to Grafana alerting, giving me visibility into my VPN overlay network so I know the moment something breaks.

This repository collects those tools and packages them as proper OPNsense plugins so they survive upgrades. Packages are signed and served from a per-release pkg repository via GitHub Pages, so installation is just a `pkg install` or a click in the Firmware UI.

**Why a separate repo?** These plugins sometimes involve a fair amount of code that would be difficult for the OPNsense team to validate and maintain, especially when adoption is likely to be limited. The OPNsense developers are focused on building a great product and shouldn't be distracted by niche tools that serve a small audience. This is not criticism -- it's simply the reality that you can't do it all. If a plugin here matures to the point where it belongs in the official [opnsense/plugins](https://github.com/opnsense/plugins) repository, great -- it will follow the standards and requirements set by the OPNsense project. Until then, contributions are welcome here.

This is as much a research project as a plugin repository. I don't take myself too seriously here -- the real goal is to learn. Building a signed pkg repo from scratch, wiring up YubiKey PIV signing, automating VM builds, writing MVC plugins for a framework I'd never touched before -- every piece taught me something I didn't know going in.

I'm an [amateur](https://winningmindtraining.com/remaining-an-amateur-a-lover-of-the-work/) Python developer -- a lover of the work rather than a professional software engineer. I do have a long history with FreeBSD from my days as a sysadmin (DevOps before it had a name), when I built and ran products like imap4all.com. These plugins lean heavily on LLM-assisted development -- particularly [Claude Code](https://claude.ai/claude-code) -- for the MVC boilerplate, build infrastructure, and FreeBSD packaging. The code works, but it may not always follow every OPNsense convention to the letter. Suggestions and contributions are very welcome -- feel free to open an issue or pull request.

> **Warning:** These plugins are provided as-is. **Use at your own risk.**

Full documentation: [brendanbank.github.io/banzai-plugins](https://brendanbank.github.io/banzai-plugins/)

## Plugins

| Plugin | Package | Version | Description |
|--------|---------|---------|-------------|
| `misc/hello_world` | `os-hello_world` | 1.1 | Hello World example plugin |
| `net/kea-ddns` | `os-kea-ddns` | 2.6 | Kea DHCP Dynamic DNS support |
| `sysutils/metrics_exporter` | `os-metrics_exporter` | 1.5 | Prometheus exporter for OPNsense metrics |

Signed packages are published for the OPNsense **26.1** (`FreeBSD:14:amd64`) and
**26.7** (`FreeBSD:15:amd64`) series. `os-kea-ddns` 2.6 supports OPNsense 26.7.

## Installation

### 1. Trust the repository signing key

All packages are signed. Before installing, set up the signing fingerprint on your firewall:

```sh
mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted
mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/revoked

cat > /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted/repo.fingerprint <<'EOF'
function: "sha256"
fingerprint: "05b9f1db7cbc08fc780c463a47f88533e55083ff2853fe684aea492bed8be0a9"
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
│   ├── FreeBSD:14:amd64/
│   │   └── 26.1/
│   │       ├── repo/           # Signed stable pkg repo
│   │       └── dev/
│   │           └── repo/       # Signed dev pkg repo (--dev builds)
│   └── FreeBSD:15:amd64/
│       └── 26.7/
│           └── repo/           # Signed stable pkg repo (26.7)
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

### Development builds

Build `-devel` packages for testing unreleased changes:

```sh
./build.sh --dev <firewall-hostname>
```

This uses the opnsense-plugins `PLUGIN_DEVEL` mechanism to produce packages with an `os-<name>-devel` suffix (e.g., `os-kea-ddns-devel`). Devel packages have `PLUGIN_TIER=4` and automatically conflict with their stable counterpart — installing one removes the other.

Dev packages are published to a separate repo path (`docs/<ABI>/<series>/dev/repo/`) and signed with the same key. When you push the `devel` branch, a GitHub Actions workflow automatically deploys the dev repo to GitHub Pages alongside the stable repo.

**Setting up the dev repo on a firewall:**

```sh
SERIES=$(opnsense-version -a)

cat > /usr/local/etc/pkg/repos/banzai-plugins-dev.conf <<EOF
banzai-plugins-dev: {
  url: "https://brendanbank.github.io/banzai-plugins/\${ABI}/${SERIES}/dev/repo",
  signature_type: "fingerprints",
  fingerprints: "/usr/local/etc/pkg/fingerprints/banzai-plugins",
  enabled: yes
}
EOF
sudo pkg update
```

**Installing devel packages:**

```sh
# Install a devel package (automatically removes the stable version)
sudo pkg install os-kea-ddns-devel

# Switch back to stable
sudo pkg install -r banzai-plugins os-kea-ddns

# Disable the dev repo when done testing
sudo sed -i '' 's/enabled: yes/enabled: no/' \
  /usr/local/etc/pkg/repos/banzai-plugins-dev.conf
```

Devel packages also appear in **System > Firmware > Plugins** when the dev repo is enabled.

You can combine `--dev` with `--test` to build devel packages without signing:

```sh
./build.sh --test --dev <firewall-hostname>
```

### Building on the firewall

You can build plugins directly on an OPNsense firewall without `build.sh`. Clone the repo, set up the build infrastructure, and use `make package` in any plugin directory:

```sh
git clone --recurse-submodules git@github.com:brendanbank/banzai-plugins.git
cd banzai-plugins
make setup
cd net/kea-ddns
make package
ls -la work/pkg/os-kea-ddns-*.pkg
```

Install the built package:

```sh
pkg add work/pkg/os-kea-ddns-*.pkg
```

## CI/CD

A GitHub Actions workflow (`.github/workflows/publish-dev-repo.yml`) deploys to GitHub Pages on every push to `main` or `devel`. It merges:

- **`main`** — stable repo, documentation, and site assets
- **`devel`** — signed dev repo packages

This means pushing `docs/` changes to either branch automatically updates the live site and pkg repos.

## Releasing

1. Bump `PLUGIN_VERSION` in `<category>/<plugin>/Makefile`
2. Update changelog in `<category>/<plugin>/pkg-descr`
3. `./build.sh <firewall>`
4. Commit source + docs changes, tag `v<version>`, push with tags
5. GitHub Pages is updated automatically via the workflow
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
