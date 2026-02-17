# OPNsense Build Server Tools

Automate the full OPNsense VM image build lifecycle: create a FreeBSD build
server, bootstrap OPNsense source repos, build VM images, and deploy them to
KVM guests — all remotely via SSH from your workstation.

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Commands](#commands)
  - [create-vm](#create-vm)
  - [provision](#provision)
  - [bootstrap](#bootstrap)
  - [update](#update)
  - [sync-device](#sync-device)
  - [build](#build)
  - [status](#status)
  - [deploy](#deploy)
  - [series](#series)
- [Device Configuration](#device-configuration)
- [Workflow Examples](#workflow-examples)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Quick Start

```sh
# 1. Copy and edit the config
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
vi tools/opnsense-build.conf

# 2. Create a build VM (or use an existing FreeBSD machine)
./tools/opnsense-build.sh create-vm

# 3. Bootstrap OPNsense source repos
./tools/opnsense-build.sh bootstrap

# 4. Build a VM image
./tools/opnsense-build.sh build

# 5. Deploy to a test VM
./tools/opnsense-build.sh deploy
```

## Prerequisites

### On your workstation (macOS or Linux)

- SSH client with key-based authentication to the KVM host and build server
- SSH agent running (needed for `deploy` command's agent forwarding)

### On the KVM host (for `create-vm` and `deploy`)

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
- `git` and `sudo` installed (the `provision` command handles this)

The `create-vm` command can create and provision a build server from scratch.
Alternatively, use `provision` on an existing FreeBSD machine.

## Configuration

Copy the sample config and edit it:

```sh
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
```

The config file is shell-sourceable (key=value). It is git-ignored — each
developer maintains their own. Config file search order:

1. `$OPNSENSE_BUILD_CONF` environment variable
2. `tools/opnsense-build.conf` (same directory as the script)
3. `~/.config/opnsense-build.conf`

### Required settings

| Variable | Description | Example |
|----------|-------------|---------|
| `BUILD_HOST` | SSH target for the build server | `brendan@10.0.10.138` |
| `SERIES` | OPNsense release series | `26.1` |

### VM creation settings (for `create-vm`)

| Variable | Default | Description |
|----------|---------|-------------|
| `KVM_HOST` | *(none)* | SSH target for the KVM/libvirt host |
| `KVM_GUEST_DIR` | `/var/vms/guests` | Guest disk image directory on KVM host |
| `BUILD_VM_NAME` | `fbsd-build` | VM name in libvirt |
| `BUILD_VM_CPUS` | `4` | Number of vCPUs |
| `BUILD_VM_MEMORY` | `16384` | RAM in MB |
| `BUILD_VM_DISK` | `100` | Disk size in GB |
| `BUILD_VM_NETWORK` | `default` | Libvirt network name |
| `FREEBSD_VERSION` | `14.3` | FreeBSD version to install |
| `SSH_PUBKEY` | *(none)* | SSH public key (string or file path) |
| `BUILD_USER` | *(none)* | Unprivileged user to create |

### Build settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVICE_CONF` | `../../BANZAI.conf` | Path to device config (relative to `tools/`) |
| `DEVICE` | `BANZAI` | Device name for `make` (matches `.conf` filename) |
| `VM_FORMAT` | `qcow2` | Image format (`qcow2`, `raw`, `vmdk`) |

### Remote paths

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_TOOLSDIR` | `/usr/tools` | OPNsense tools repo |
| `REMOTE_SRCDIR` | `/usr/src` | FreeBSD src |
| `REMOTE_COREDIR` | `/usr/core` | OPNsense core |
| `REMOTE_PLUGINSDIR` | `/usr/plugins` | OPNsense plugins |
| `REMOTE_PORTSDIR` | `/usr/ports` | FreeBSD ports |

### Deployment settings (for `deploy`)

| Variable | Default | Description |
|----------|---------|-------------|
| `KVM_GUEST_NAME` | *(none)* | Default guest VM to deploy to |

### Example configuration

```sh
BUILD_HOST=brendan@10.0.10.138
SERIES=26.1

KVM_HOST=vm.example.com
KVM_GUEST_DIR=/var/vms/guests
BUILD_VM_NAME=fbsd-build
BUILD_VM_CPUS=8
BUILD_VM_MEMORY=16384
BUILD_VM_DISK=120
BUILD_VM_NETWORK=br0
FREEBSD_VERSION=14.3
SSH_PUBKEY=~/.ssh/id_ed25519.pub
BUILD_USER=brendan

KVM_GUEST_NAME=opn-test
```

## Commands

### create-vm

Create a new FreeBSD VM on the KVM host and provision it as a build server.

```sh
./tools/opnsense-build.sh create-vm
```

**What it does:**

1. Checks that the KVM host has all required tools installed
2. Verifies no VM with the same name already exists
3. Downloads the FreeBSD BASIC-CLOUDINIT image (cached for reuse)
4. Creates a VM disk from the base image and resizes it
5. Generates a cloud-init ISO (`cidata.iso`) with a provisioning script
6. Boots the VM with the cloud-init ISO attached
7. Detects the VM's IP address (from DHCP lease in serial console log)
8. Waits for SSH to become available (2-3 minutes while provisioning runs)
9. Runs the provisioning steps (package install, sudo config, resource check)

**Cloud-init details:**

The `create-vm` command uses FreeBSD's BASIC-CLOUDINIT image variant, which
includes `nuageinit` for processing NoCloud-style cloud-init data. A cidata
ISO (volume label `cidata`) is attached as a CD-ROM containing:

- `meta-data` — instance ID and hostname
- `user-data` — a shell script (not cloud-config YAML, because FreeBSD 14.3's
  nuageinit doesn't support `runcmd`, `write_files`, or `packages`)

The user-data script:

- Sets up root SSH access with the configured public key
- Creates the build user (if `BUILD_USER` is set) with wheel group membership
- Installs `git` and `sudo` via `pkg`
- Configures NOPASSWD sudo for the wheel group
- Grows the filesystem to fill the disk

**After creation:**

The command prints the VM's IP address and instructions for updating your
config. Add the IP to `BUILD_HOST` in your config, then run `bootstrap`.

**Serial console:**

Boot output is logged to `${KVM_GUEST_DIR}/${BUILD_VM_NAME}/console.log` on
the KVM host. Useful for debugging boot or provisioning failures:

```sh
ssh your-kvm-host "cat /var/vms/guests/fbsd-build/console.log"
```

### provision

Provision an existing FreeBSD machine as a build server.

```sh
./tools/opnsense-build.sh provision
```

Use this when you already have a FreeBSD machine (not created by `create-vm`)
that you want to use as a build server. It is idempotent — safe to run
multiple times.

**What it does:**

1. Tests SSH connectivity to `BUILD_HOST`
2. Detects the FreeBSD version
3. Bootstraps `pkg` and installs `git` and `sudo`
4. Creates the build user (if `BUILD_USER` is set and connected as root)
5. Configures NOPASSWD sudo for the wheel group
6. Checks disk space and RAM, warns if below recommended minimums

**Notes:**

- Works whether you connect as root or as an unprivileged user with sudo
- If connecting as root with `BUILD_USER` set, it creates the user and copies
  root's SSH authorized keys to the new user
- After provisioning as root, update `BUILD_HOST` to use the unprivileged user

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

**After switching:** Update `SERIES` in your config file to match. Then run
`build` to create an image for the new series.

**Note:** A series is only available when the OPNsense project has published
the tools config and stable branches for it. For example, 26.7 won't be
available until its release candidate phase.

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
# Configure
cp tools/opnsense-build.conf.sample tools/opnsense-build.conf
# Edit: set KVM_HOST, SSH_PUBKEY, BUILD_USER, SERIES

# Create the VM and provision it
./tools/opnsense-build.sh create-vm
# Note the IP address from the output, update BUILD_HOST in config

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
├── opnsense-build.sh              # Main entry point (subcommand dispatch)
├── opnsense-build.conf.sample     # Documented sample configuration
├── opnsense-build.conf            # User config (git-ignored)
├── lib/
│   └── common.sh                  # Shared helpers
└── README.md                      # This file
```

### How it works

The script operates entirely over SSH. Your workstation is the control plane;
the build server does the heavy lifting. There is no agent or daemon on the
build server — everything runs as remote commands.

```
┌─────────────┐    SSH     ┌──────────────┐
│ Workstation  │ ────────→ │ Build Server │  (FreeBSD, /usr/tools)
│  (macOS)     │           │  (fbsd-build)│
└──────┬───────┘           └──────────────┘
       │                          │
       │ SSH                      │ SCP (agent-forwarded)
       ▼                          ▼
┌─────────────┐           ┌──────────────┐
│  KVM Host   │           │  Guest VM    │
│(vm.example) │  libvirt  │  (opn-test)  │
└─────────────┘ ────────→ └──────────────┘
```

### Helper library (`lib/common.sh`)

Shared functions used across all commands:

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

### create-vm: VM doesn't get an IP address

The script detects the IP by parsing the serial console log for DHCP lease
information. If detection fails:

1. Check the console log:
   ```sh
   ssh your-kvm-host "cat /var/vms/guests/fbsd-build/console.log"
   ```
2. Try ARP-based detection from the KVM host:
   ```sh
   ssh your-kvm-host "sudo virsh domifaddr fbsd-build --source arp"
   ```
3. Check that the libvirt network has DHCP enabled.

### create-vm: SSH never becomes available

The user-data provisioning script runs at first boot and takes 2-3 minutes.
If SSH isn't available after 5 minutes:

1. Connect to the VM console:
   ```sh
   ssh your-kvm-host "sudo virsh console fbsd-build"
   ```
2. Check if the user-data script ran. Look at `/var/log/messages` for nuageinit
   output.
3. Verify that the SSH public key in your config is correct.

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
- For build VMs created by `create-vm`: check that `SSH_PUBKEY` in your config
  is correct

### General: "Permission denied" on git or make commands

All repositories on the build server live under `/usr/` and are root-owned.
The script uses `sudo` for all git and make operations. Verify that the build
user has NOPASSWD sudo:

```sh
ssh build-host "sudo -n echo ok"
```

If this prompts for a password, re-run `provision` to fix sudo configuration.
