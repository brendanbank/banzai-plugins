# OPNsense Build Server Tools

Automate the full OPNsense VM image build lifecycle: create a FreeBSD build
server, bootstrap OPNsense source repos, build VM images, and deploy them to
KVM guests.

Three scripts split responsibilities:

- **`create-build-vm.sh`** — runs on the KVM host to create a FreeBSD VM
- **`opnsense-build.sh`** — runs on your workstation to orchestrate remote builds
- **`opnsense-build-server.sh`** — runs on the build server for direct builds

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [create-build-vm.sh](#create-build-vmsh)
- [opnsense-build.sh](#opnsense-buildsh)
  - [bootstrap](#bootstrap)
  - [update](#update)
  - [sync-device](#sync-device)
  - [build](#build)
  - [status](#status)
  - [deploy](#deploy)
  - [series](#series)
- [opnsense-build-server.sh](#opnsense-build-serversh)
- [Device Configuration](#device-configuration)
- [Workflow Examples](#workflow-examples)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Quick Start

### New VM (on a KVM host)

```sh
# On the KVM host: create a FreeBSD build VM
./tools/create-build-vm.sh create \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --build-user brendan

# Note the IP address from the output
```

### Existing FreeBSD machine

Ensure `git` and `sudo` are installed, and the build user has NOPASSWD sudo.

### Bootstrap and build (from your workstation)

```sh
# 1. Copy and edit the config
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
# Set BUILD_HOST and SERIES

# 2. Bootstrap OPNsense source repos
./tools/opnsense-build.sh bootstrap

# 3. Build a VM image
./tools/opnsense-build.sh build

# 4. Deploy to a test VM
./tools/opnsense-build.sh deploy
```

## Prerequisites

### On your workstation (macOS or Linux)

- SSH client with key-based authentication to the build server (and KVM host
  for deploy)
- SSH agent running (needed for `deploy` command's agent forwarding)

### On the KVM host (for `create-build-vm.sh` and `deploy`)

The KVM host is the machine that runs libvirt/QEMU virtual machines. Required
packages:

- `libvirt-daemon-system` — libvirt
- `virtinst` — `virt-install` command
- `qemu-utils` — `qemu-img` command
- `genisoimage` — ISO creation for cloud-init
- `wget` — downloading FreeBSD images
- `xz-utils` — decompressing FreeBSD images

Install on Debian/Ubuntu:

```sh
apt install libvirt-daemon-system virtinst qemu-utils genisoimage wget xz-utils
```

### On the build server (FreeBSD)

A FreeBSD machine (physical or virtual) with:

- FreeBSD version matching the target OPNsense series (e.g., FreeBSD 14.3 for
  OPNsense 26.1)
- Minimum 40 GB free disk (80 GB+ recommended for caching build artifacts)
- Minimum 8 GB RAM
- Network access to GitHub and FreeBSD package mirrors
- `git` and `sudo` installed

The `create-build-vm.sh` script handles VM creation and provisioning
automatically.

## Configuration

### opnsense-build.conf (workstation)

Copy the sample config and edit it:

```sh
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
```

The config file is shell-sourceable (key=value). It is git-ignored — each
developer maintains their own. Config file search order:

1. `$OPNSENSE_BUILD_CONF` environment variable
2. `tools/opnsense-build.conf` (same directory as the script)
3. `~/.config/opnsense-build.conf`

#### Required settings

| Variable | Description | Example |
|----------|-------------|---------|
| `BUILD_HOST` | SSH target for the build server | `brendan@10.0.10.138` |
| `SERIES` | OPNsense release series | `26.1` |

#### Build settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVICE_CONF` | `../../BANZAI.conf` | Path to device config (relative to `tools/`) |
| `DEVICE` | `BANZAI` | Device name for `make` (matches `.conf` filename) |
| `VM_FORMAT` | `qcow2` | Image format (`qcow2`, `raw`, `vmdk`) |

#### Remote paths

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_TOOLSDIR` | `/usr/tools` | OPNsense tools repo |
| `REMOTE_SRCDIR` | `/usr/src` | FreeBSD src |
| `REMOTE_COREDIR` | `/usr/core` | OPNsense core |
| `REMOTE_PLUGINSDIR` | `/usr/plugins` | OPNsense plugins |
| `REMOTE_PORTSDIR` | `/usr/ports` | FreeBSD ports |

#### Deployment settings

| Variable | Default | Description |
|----------|---------|-------------|
| `KVM_HOST` | *(none)* | SSH target for the KVM/libvirt host |
| `KVM_GUEST_DIR` | `/var/vms/guests` | Guest disk image directory on KVM host |
| `KVM_GUEST_NAME` | *(none)* | Default guest VM to deploy to |

#### Example configuration

```sh
BUILD_HOST=brendan@10.0.10.138
SERIES=26.1

KVM_HOST=vm.example.com
KVM_GUEST_NAME=opn-test
```

### opnsense-build-server.conf (build server)

This config is written automatically by `opnsense-build.sh bootstrap` and
`opnsense-build.sh series`. It lives at `/etc/opnsense-build-server.conf` on
the build server. Override with `OPNSENSE_BUILD_SERVER_CONF` env var.

| Variable | Default | Description |
|----------|---------|-------------|
| `SERIES` | *(required)* | OPNsense release series |
| `DEVICE` | `BANZAI` | Device name |
| `VM_FORMAT` | `qcow2` | Image format |
| `TOOLSDIR` | `/usr/tools` | OPNsense tools repo path |

## create-build-vm.sh

Self-contained script that runs **locally on a KVM/libvirt host**. Creates a
FreeBSD VM provisioned as an OPNsense build server.

```sh
# Create a VM
./tools/create-build-vm.sh create --ssh-pubkey ~/.ssh/id_ed25519.pub

# Create with custom resources
./tools/create-build-vm.sh create \
    --name fbsd-build \
    --cpus 8 \
    --memory 16384 \
    --disk 120 \
    --network br0 \
    --freebsd-version 14.3 \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --build-user brendan

# Delete a VM
./tools/create-build-vm.sh delete --name fbsd-build
```

### Create options

| Flag | Default | Description |
|------|---------|-------------|
| `--name` | `fbsd-build` | VM name in libvirt |
| `--cpus` | `4` | Number of vCPUs |
| `--memory` | `16384` | RAM in MB |
| `--disk` | `100` | Disk size in GB |
| `--network` | `default` | Libvirt network name |
| `--freebsd-version` | `14.3` | FreeBSD version to install |
| `--guest-dir` | `/var/vms/guests` | Guest disk image directory |
| `--ssh-pubkey` | *(required)* | SSH public key (string or file path) |
| `--build-user` | *(none)* | Unprivileged user to create |

All flags have env var equivalents: `VM_NAME`, `VM_CPUS`, `VM_MEMORY`,
`VM_DISK`, `VM_NETWORK`, `FREEBSD_VERSION`, `GUEST_DIR`, `SSH_PUBKEY`,
`BUILD_USER`.

### What create does

1. Checks that all required KVM tools are installed
2. Verifies no VM with the same name already exists
3. Downloads the FreeBSD BASIC-CLOUDINIT image (cached for reuse)
4. Creates a VM disk from the base image and resizes it
5. Generates a cloud-init ISO (`cidata.iso`) with a provisioning script
6. Boots the VM with the cloud-init ISO attached
7. Detects the VM's IP address (from DHCP lease in serial console log)
8. Waits for SSH to become available (2-3 minutes while provisioning runs)
9. Verifies provisioning completed (resource checks)

**Cloud-init details:**

The script uses FreeBSD's BASIC-CLOUDINIT image variant, which includes
`nuageinit` for processing NoCloud-style cloud-init data. A cidata ISO (volume
label `cidata`) is attached as a CD-ROM containing:

- `meta-data` — instance ID and hostname
- `user-data` — a shell script (not cloud-config YAML, because FreeBSD 14.3's
  nuageinit doesn't support `runcmd`, `write_files`, or `packages`)

The user-data script runs during first boot via nuageinit (**before networking
is available**), so it handles only local operations:

- Sets up root SSH access with the configured public key
- Creates the build user (if `--build-user` is set) with wheel group membership
- Enables `PermitRootLogin prohibit-password` in sshd_config

After the VM boots and SSH becomes available, the script installs packages and
configures sudo over SSH:

- Installs `git` and `sudo` via `pkg`
- Configures NOPASSWD sudo for the wheel group

The base image already has `growfs_enable=YES`, so the filesystem is
automatically grown to fill the disk on first boot.

**After creation:**

The command prints the VM's IP address and instructions for updating your
config. Add the IP to `BUILD_HOST` in your `opnsense-build.conf`, then run
`opnsense-build.sh bootstrap`.

**Serial console:**

Boot output is logged to `${GUEST_DIR}/${VM_NAME}/console.log`. Useful for
debugging boot or provisioning failures.

## opnsense-build.sh

Workstation-side orchestrator that runs commands on the build server via SSH.

### bootstrap

Clone OPNsense source repositories and configure the build server for a
release series.

```sh
./tools/opnsense-build.sh bootstrap
```

**What it does:**

1. Tests SSH connectivity
2. Clones the OPNsense tools repo to `/usr/tools` (if not already present)
3. Verifies that `config/<series>/` exists in the tools repo (the series must
   be available upstream)
4. Runs `make update` from the tools repo, which clones all remaining repos
   (`src`, `core`, `plugins`, `ports`) with the correct git URLs and branch
   names
5. Syncs the device config (BANZAI.conf) to the build server
6. Writes `/etc/opnsense-build-server.conf` with the current settings

**Repository layout on the build server:**

| Path | Repository | Branch |
|------|-----------|--------|
| `/usr/tools` | opnsense/tools | `master` |
| `/usr/src` | opnsense/src | `stable/<series>` |
| `/usr/core` | opnsense/core | `stable/<series>` |
| `/usr/plugins` | opnsense/plugins | `stable/<series>` |
| `/usr/ports` | opnsense/ports | `master` |

All repos are root-owned (cloned with `sudo`). The script handles this
transparently.

**Idempotency:** Safe to run multiple times. Existing repos are updated rather
than re-cloned.

### update

Pull the latest code for all repositories.

```sh
./tools/opnsense-build.sh update
```

Runs `make update` in the tools repo, which fetches and pulls all repositories
with the correct branches for the configured series.

### sync-device

Sync the device config file to the build server.

```sh
./tools/opnsense-build.sh sync-device
```

Copies the device config (default: `BANZAI.conf` from the workspace root) to
`/usr/tools/device/` on the build server. The device directory is root-owned,
so the file is first copied to `/tmp` via `scp`, then moved into place with
`sudo`.

**When to use:** After editing `BANZAI.conf` locally, run this to push changes
to the build server before rebuilding.

### build

Build an OPNsense VM image.

```sh
# Full build (all stages)
./tools/opnsense-build.sh build

# Individual stages
./tools/opnsense-build.sh build base
./tools/opnsense-build.sh build kernel
./tools/opnsense-build.sh build ports
./tools/opnsense-build.sh build core
./tools/opnsense-build.sh build plugins
./tools/opnsense-build.sh build vm

# Multiple stages
./tools/opnsense-build.sh build base kernel
```

**Build stages:**

| Stage | What it builds | Typical time |
|-------|---------------|-------------|
| `base` | FreeBSD base system | ~20 minutes |
| `kernel` | FreeBSD kernel | ~5 minutes |
| `ports` | FreeBSD ports/packages | ~2.5 hours |
| `core` | OPNsense core system | ~5 minutes |
| `plugins` | OPNsense plugins | ~2 minutes |
| `vm` | Final VM image assembly | ~5 minutes (cached) |

A full build with no cached artifacts takes approximately 3 hours. Subsequent
builds are much faster because intermediate artifacts (sets, packages) are
cached.

**Build output:**

Images are written to `/usr/local/opnsense/build/<series>/amd64/images/` on
the build server. The filename includes a timestamp, e.g.,
`OPNsense-202602171947-vm-amd64.qcow2`.

All build commands run with `BATCH=yes` for unattended operation and
`DEVICE=BANZAI` (or your configured device name).

**Notes:**

- Build output streams in real-time over SSH
- Use Ctrl-C to interrupt a build cleanly
- Individual stages are useful for iterating: rebuild only `core` after a code
  change, then `vm` to re-assemble the image

### status

Show the current state of the build server.

```sh
./tools/opnsense-build.sh status
```

Displays:

- FreeBSD version
- Current branch and latest commit for each repository
- Whether the series config exists in the tools repo
- Whether the device config exists
- Build artifacts (images) with timestamps and sizes
- Disk space and RAM

This is a read-only command — safe to run anytime.

### deploy

Deploy a built VM image to a KVM guest.

```sh
# Deploy to the default guest (KVM_GUEST_NAME from config)
./tools/opnsense-build.sh deploy

# Deploy to a specific guest
./tools/opnsense-build.sh deploy --guest opn-test
```

**What it does:**

1. Finds the most recent `.qcow2` image on the build server
2. Stops the target guest VM (if running)
3. Copies the image from the build server to the KVM host via SSH agent
   forwarding (`ssh -A`)
4. Starts the guest VM

**Important notes:**

- The build server and guest VM should be on the same KVM host (the copy goes
  through the KVM host rather than through your workstation)
- Your SSH agent must be running with keys loaded (the deploy uses `-A` for
  agent forwarding so the KVM host can authenticate to the build server)
- New images have new SSH host keys — run `ssh-keygen -R <guest-ip>` after
  deploying

### series

Switch all repositories to a different OPNsense release series.

```sh
./tools/opnsense-build.sh series 26.7
```

**What it does:**

1. Fetches the tools repo to get the latest config
2. Verifies that `config/<series>/` exists (the series must be available
   upstream)
3. Runs `make update SETTINGS=<series>` to switch all repos to the new series
   branches
4. Updates `/etc/opnsense-build-server.conf` with the new series

**After switching:** Update `SERIES` in your config file to match. Then run
`build` to create an image for the new series.

**Note:** A series is only available when the OPNsense project has published
the tools config and stable branches for it. For example, 26.7 won't be
available until its release candidate phase.

## opnsense-build-server.sh

Wrapper script for running builds directly on the build server. Useful when you
SSH into the build server and want to build without the workstation orchestrator.

Lives in `banzai-plugins/tools/` — check out the repo on the build server.

```sh
# On the build server:
opnsense-build-server.sh build              # full build
opnsense-build-server.sh build core vm      # rebuild core + assemble image
opnsense-build-server.sh status             # show server state
opnsense-build-server.sh update             # pull latest repos
```

### Commands

| Command | Description |
|---------|-------------|
| `build [stage...]` | Build VM image (same stages as opnsense-build.sh) |
| `status` | Show repos, artifacts, disk/RAM — all local commands |
| `update` | `sudo make -C /usr/tools update` |

### Configuration

Reads from `/etc/opnsense-build-server.conf` (written by bootstrap/series
commands) or env vars. Override config path with `OPNSENSE_BUILD_SERVER_CONF`.

## Makefile

Convenience targets for building directly on the build server. If you check out
the `banzai-plugins` repo on the build server, you can run builds from
`tools/`:

```sh
cd banzai-plugins/tools
make build                    # full VM image build
make build core vm            # not supported — use individual targets
make core                     # rebuild OPNsense core
make vm                       # assemble VM image
make status                   # show repos, artifacts, resources
make update                   # pull latest code
make clean                    # clean build artifacts
```

Override settings on the command line:

```sh
make build SERIES=26.7 DEVICE=BANZAI
```

Reads `/etc/opnsense-build-server.conf` for defaults (same config as
`opnsense-build-server.sh`).

## Device Configuration

A device config is a shell script that customizes the OPNsense VM image. It
defines variables and hook functions that the build system calls during image
assembly. A sample is provided at `tools/device.conf.sample`.

### Creating a device config

1. Copy the sample:
   ```sh
   cp tools/device.conf.sample MYDEVICE.conf
   ```

2. Edit the file:
   - Set `PRODUCT_ADDITIONS` to any packages you want pre-installed
   - Customize the `config.xml` embedded in `vm_hook()`:
     - **Hostname and domain**
     - **Users**: add your username, set a bcrypt password, add your SSH public
       key (base64-encoded)
     - **Groups**: add your user's UID as a `<member>` element in the admins
       group
     - **Network**: adjust interfaces and firewall rules
     - **SSH**: enable/disable root login, password auth

3. Update `opnsense-build.conf`:
   ```sh
   DEVICE_CONF=../../MYDEVICE.conf    # path relative to tools/ directory
   DEVICE=MYDEVICE                     # must match the .conf filename (without extension)
   ```

4. Sync to the build server:
   ```sh
   ./tools/opnsense-build.sh sync-device
   ```

### Key settings in config.xml

| Setting | XML path | Notes |
|---------|----------|-------|
| Hostname | `system/hostname` | |
| SSH enabled | `system/ssh/enabled` | Set to `enabled` |
| Root SSH login | `system/ssh/permitrootlogin` | `1` to allow |
| Console login required | `system/disableconsolemenu` | `1` = require login at console |
| Passwordless sudo | `system/sudo_allow_wheel` | `2` = NOPASSWD for wheel group |
| User SSH key | `user/authorizedkeys` | Base64-encoded: `echo 'ssh-rsa ...' \| base64` |
| User password | `user/password` | Bcrypt hash (`$2y$` prefix) |
| Group members | `group/member` | One `<member>` element per UID — **not** comma-separated |
| LAN interface | `interfaces/lan/if` | `vtnet0` for virtio (KVM/QEMU) |
| LAN addressing | `interfaces/lan/ipaddr` | `dhcp` or a static IP |

### Generating passwords and keys

```sh
# Generate a bcrypt password hash (run on any machine with PHP)
php -r "echo password_hash('your-password', PASSWORD_BCRYPT) . \"\\n\";"

# Base64-encode an SSH public key for config.xml
cat ~/.ssh/id_ed25519.pub | base64

# On macOS (no -w flag needed):
cat ~/.ssh/id_ed25519.pub | base64

# On Linux:
cat ~/.ssh/id_ed25519.pub | base64 -w0
```

### Adding a user

To add a user named `alice` with UID 2000:

1. Add a `<user>` block in the `<system>` section:
   ```xml
   <user>
     <uid>2000</uid>
     <name>alice</name>
     <disabled>0</disabled>
     <scope>user</scope>
     <authorizedkeys>BASE64_ENCODED_SSH_KEY</authorizedkeys>
     <password>BCRYPT_HASH</password>
     <shell>/bin/sh</shell>
     <descr>Alice</descr>
   </user>
   ```

2. Add the UID to the admins group (each UID is a separate `<member>` element):
   ```xml
   <group>
     <name>admins</name>
     <member>0</member>
     <member>2000</member>
   </group>
   ```

3. Update `<nextuid>` to be higher than the highest UID used.

## Workflow Examples

### Setting up a new build environment from scratch

```sh
# On the KVM host: create a build VM
./tools/create-build-vm.sh create \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --build-user brendan
# Note the IP address from the output

# On your workstation: configure
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
# Set BUILD_HOST=brendan@<ip> and SERIES=26.1

# Clone all OPNsense repos
./tools/opnsense-build.sh bootstrap

# Build the first image (takes ~3 hours)
./tools/opnsense-build.sh build

# Deploy to a test VM
./tools/opnsense-build.sh deploy
```

### Daily development cycle

```sh
# Pull latest upstream changes
./tools/opnsense-build.sh update

# Rebuild just what changed (e.g., core changes)
./tools/opnsense-build.sh build core
./tools/opnsense-build.sh build vm

# Deploy the new image
./tools/opnsense-build.sh deploy
```

### Building directly on the server

```sh
# SSH to the build server
ssh build-host

# Build using the local wrapper
opnsense-build-server.sh build core vm
opnsense-build-server.sh status
```

### After editing the device config

```sh
# Push the updated BANZAI.conf
./tools/opnsense-build.sh sync-device

# Rebuild and deploy
./tools/opnsense-build.sh build vm
./tools/opnsense-build.sh deploy
```

### Checking build server health

```sh
./tools/opnsense-build.sh status
```

### Preparing for a new OPNsense release

```sh
# Switch to the new series (when available upstream)
./tools/opnsense-build.sh series 26.7
# Update SERIES=26.7 in config

# Full rebuild for the new series
./tools/opnsense-build.sh build
```

## Architecture

### File layout

```
tools/
├── create-build-vm.sh             # VM creation (runs on KVM host)
├── opnsense-build.sh              # Orchestrator (runs on workstation)
├── opnsense-build-server.sh       # Build wrapper (synced to build server)
├── piv-sign-agent.py              # PIV signing agent (runs on workstation)
├── sign-repo.py                   # pkg signing command (runs on build host)
├── Makefile                       # Convenience targets (runs on build server)
├── opnsense-build.conf.sample     # Documented sample configuration
├── opnsense-build.conf            # User config (git-ignored)
├── lib/
│   └── common.sh                  # Shared helpers for opnsense-build.sh
└── README.md                      # This file
```

### How it works

Three scripts handle different parts of the workflow:

```
┌─────────────┐  create-build-vm.sh  ┌──────────────┐
│  KVM Host   │ ──────────────────→  │  Build VM    │
│             │   (runs locally)     │  (FreeBSD)   │
└──────┬──────┘                      └──────┬───────┘
       │                                    │
       │ SSH (deploy)                       │ opnsense-build-server.sh
       │                                    │ (runs locally on server)
       │                                    │
┌──────┴──────┐    SSH (orchestrate)        │
│ Workstation │ ────────────────────────────┘
│  (macOS)    │  opnsense-build.sh
└─────────────┘
```

- **`create-build-vm.sh`** runs directly on the KVM host. No SSH wrappers —
  it calls `virsh`, `qemu-img`, etc. locally. Output tells you the VM's IP
  so you can configure `BUILD_HOST`.

- **`opnsense-build.sh`** runs on your workstation. It SSH's into the build
  server for all operations (bootstrap, build, status, deploy). The `bootstrap`
  command writes the server-side config.

- **`opnsense-build-server.sh`** runs directly on the build server. It wraps
  `make` commands so you can build without needing the workstation orchestrator.

### Helper library (`lib/common.sh`)

Shared functions used by `opnsense-build.sh`:

- **Logging:** `die()`, `info()`, `step()`, `warn()` — consistent output
  formatting
- **Config:** `load_config()`, `validate_config()`, `validate_build_host()`,
  `validate_kvm_host()` — config file loading and validation
- **SSH:** `remote()`, `remote_sudo()`, `scp_to()`, `scp_from()`, `kvm_ssh()`,
  `kvm_sudo()` — SSH wrappers for build server and KVM host
- **Git:** `remote_git_clone()`, `remote_git_fetch()`,
  `remote_git_checkout()`, `remote_git_branch()`, `remote_git_log1()` — remote
  git operations (all use `sudo` because `/usr` repos are root-owned)

### OPNsense build system

The OPNsense tools repo (`/usr/tools`) contains the build infrastructure.
The key command is:

```sh
make vm-qcow2 DEVICE=BANZAI BATCH=yes
```

This runs through all build stages (base, kernel, ports, core, plugins) and
assembles a VM image. The `DEVICE` parameter selects the device config
(`/usr/tools/device/BANZAI.conf`), which customizes the image:

- Network configuration (DHCP, interfaces)
- Pre-installed packages
- SSH and console settings
- User accounts and sudo configuration
- Any OPNsense settings baked into `config.xml`

Build artifacts are cached in `/usr/local/opnsense/build/<series>/`. After the
first full build, subsequent builds only rebuild changed stages, making
incremental builds much faster.

### Device config

The device config (`BANZAI.conf`) is a shell script sourced by the OPNsense
build system. It defines functions and variables that customize the VM image.
The source of truth is in the workspace root; `sync-device` copies it to the
build server.

## Troubleshooting

### create-build-vm.sh: VM doesn't get an IP address

The script detects the IP by parsing the serial console log for DHCP lease
information. If detection fails:

1. Check the console log:
   ```sh
   cat /var/vms/guests/fbsd-build/console.log
   ```
2. Try ARP-based detection:
   ```sh
   sudo virsh domifaddr fbsd-build --source arp
   ```
3. Check that the libvirt network has DHCP enabled.

### create-build-vm.sh: SSH never becomes available

The user-data provisioning script runs at first boot and takes 2-3 minutes.
If SSH isn't available after 5 minutes:

1. Connect to the VM console:
   ```sh
   sudo virsh console fbsd-build
   ```
2. Check if the user-data script ran. Look at `/var/log/messages` for nuageinit
   output.
3. Verify that the SSH public key is correct.

### bootstrap: "config/<series>/ does not exist"

The OPNsense tools repo must have a config directory for your target series.
Not all series are available at all times:

- A series becomes available during its release candidate phase
- Check what's available: `ssh build-host "ls /usr/tools/config/"`
- Use `update` to pull the latest tools repo, then retry

### build: Ports build takes very long

Ports builds are the slowest stage (~2.5 hours on a 4-core VM). Tips:

- More CPUs help — individual port builds use all available cores
- Ensure sufficient RAM (8 GB+) to avoid swapping
- Ports are built sequentially (not parallelized across ports) — this is by
  OPNsense design
- After the first build, ports are cached. Only new/updated ports are rebuilt.

### deploy: "Permission denied" during image copy

The deploy command uses SSH agent forwarding (`ssh -A`) so the KVM host can
authenticate to the build server. Ensure:

1. Your SSH agent is running: `ssh-add -l`
2. The key that authenticates to the build server is loaded in the agent
3. The KVM host allows agent forwarding (default SSH config allows it)

### deploy: Can't SSH to the guest after deploying

New VM images have new SSH host keys. Clear the old key:

```sh
ssh-keygen -R <guest-ip>
```

### General: "Cannot connect via SSH"

- Verify the host is reachable: `ping <host>`
- Verify SSH key authentication works: `ssh -v <host>`
- For the build server: all commands need key-based auth (no password prompts)
- For build VMs created by `create-build-vm.sh`: check that `--ssh-pubkey`
  was correct

### General: "Permission denied" on git or make commands

All repositories on the build server live under `/usr/` and are root-owned.
The script uses `sudo` for all git and make operations. Verify that the build
user has NOPASSWD sudo:

```sh
ssh build-host "sudo -n echo ok"
```

If this prompts for a password, ensure the wheel group has NOPASSWD sudo
configured in `/usr/local/etc/sudoers`.
