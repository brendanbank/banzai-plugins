#!/bin/sh

# Copyright (C) 2026 Brendan Bank
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

#
# create-build-vm.sh — Create a FreeBSD build server VM on a KVM/libvirt host
#
# Run this script directly on the KVM host. It downloads a FreeBSD
# BASIC-CLOUDINIT image and provisions it via a cidata ISO containing a
# shell script processed by nuageinit on first boot. The script handles
# user creation, SSH keys, package installation, and sudo configuration.
# Completion is signaled by FreeBSD's native /firstboot deletion.
#
# Usage: create-build-vm.sh <command> [options]
#

set -e

# ── Logging ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
step() { echo "    $*"; }
warn() { echo "WARNING: $*" >&2; }

# ── Defaults ─────────────────────────────────────────────────────────

VM_NAME="${VM_NAME:-fbsd-build}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-16384}"
VM_DISK="${VM_DISK:-100}"
VM_NETWORK="${VM_NETWORK:-default}"
FREEBSD_VERSION="${FREEBSD_VERSION:-14.3}"
GUEST_DIR="${GUEST_DIR:-/var/vms/guests}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
BUILD_USER="${BUILD_USER:-}"

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  create [options]      Create a FreeBSD build server VM
  delete --name NAME    Delete a VM (virsh destroy + undefine + remove disk)

Create options:
  --name NAME           VM name in libvirt (default: ${VM_NAME})
  --cpus N              Number of vCPUs (default: ${VM_CPUS})
  --memory MB           RAM in MB (default: ${VM_MEMORY})
  --disk GB             Disk size in GB (default: ${VM_DISK})
  --network NAME        Libvirt network (default: ${VM_NETWORK})
  --freebsd-version V   FreeBSD version (default: ${FREEBSD_VERSION})
  --guest-dir DIR       Guest disk directory (default: ${GUEST_DIR})
  --ssh-pubkey KEY      SSH public key string or file path (required)
  --build-user USER     Unprivileged user to create (optional)

Delete options:
  --name NAME           VM name to delete (required)

Environment variables (override defaults):
  VM_NAME, VM_CPUS, VM_MEMORY, VM_DISK, VM_NETWORK,
  FREEBSD_VERSION, GUEST_DIR, SSH_PUBKEY, BUILD_USER
EOF
    exit 1
}

# ── Helpers ──────────────────────────────────────────────────────────

resolve_ssh_pubkey() {
    local key="$1"
    [ -n "${key}" ] || die "SSH public key required. Use --ssh-pubkey or set SSH_PUBKEY."

    # If it looks like a key string, use it directly
    case "${key}" in
        ssh-*|ecdsa-*)
            echo "${key}"
            return
            ;;
    esac

    # Otherwise treat as file path
    case "${key}" in
        "~/"*) key="${HOME}/${key#\~/}" ;;
    esac
    [ -f "${key}" ] || die "SSH public key file not found: ${key}"
    cat "${key}"
}

vm_ssh() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$@"
}

# ── Create ───────────────────────────────────────────────────────────

cmd_create() {
    # Parse flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)           VM_NAME="$2"; shift 2 ;;
            --cpus)           VM_CPUS="$2"; shift 2 ;;
            --memory)         VM_MEMORY="$2"; shift 2 ;;
            --disk)           VM_DISK="$2"; shift 2 ;;
            --network)        VM_NETWORK="$2"; shift 2 ;;
            --freebsd-version) FREEBSD_VERSION="$2"; shift 2 ;;
            --guest-dir)      GUEST_DIR="$2"; shift 2 ;;
            --ssh-pubkey)     SSH_PUBKEY="$2"; shift 2 ;;
            --build-user)     BUILD_USER="$2"; shift 2 ;;
            *)                die "Unknown option: $1" ;;
        esac
    done

    local ssh_pubkey
    ssh_pubkey=$(resolve_ssh_pubkey "${SSH_PUBKEY}")

    info "Creating build VM: ${VM_NAME}"
    step "${VM_CPUS} CPUs, ${VM_MEMORY}MB RAM, ${VM_DISK}GB disk"
    step "FreeBSD ${FREEBSD_VERSION}, network: ${VM_NETWORK}"

    # Check required tools
    info "Checking prerequisites"
    local missing=""
    for tool in virsh virt-install qemu-img genisoimage wget xz; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing="${missing} ${tool}"
        fi
    done
    if [ -n "${missing}" ]; then
        die "Missing tools:${missing}
Install with: apt install libvirt-daemon-system virtinst qemu-utils genisoimage wget xz-utils"
    fi
    step "All required tools available"

    # Check if VM already exists
    if sudo virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
        die "VM '${VM_NAME}' already exists. Remove it first or choose a different name."
    fi

    # Download FreeBSD BASIC-CLOUDINIT image (includes nuageinit for cloud-config)
    local image_name="FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2"
    local image_url="https://download.freebsd.org/releases/VM-IMAGES/${FREEBSD_VERSION}-RELEASE/amd64/Latest/${image_name}.xz"
    local cache_dir="/var/cache/freebsd-images"

    info "FreeBSD ${FREEBSD_VERSION} BASIC-CLOUDINIT image"
    sudo mkdir -p "${cache_dir}"

    if sudo test -f "${cache_dir}/${image_name}"; then
        step "Using cached image: ${cache_dir}/${image_name}"
    else
        if sudo test -f "${cache_dir}/${image_name}.xz"; then
            step "Using cached compressed image"
        else
            step "Downloading ${image_url}"
            sudo wget -q --show-progress -O "${cache_dir}/${image_name}.xz" "${image_url}" \
                || die "Failed to download FreeBSD image"
        fi
        step "Decompressing (this may take a minute)..."
        sudo xz -dk "${cache_dir}/${image_name}.xz"
    fi

    # Create guest directory and disk
    local guest_dir="${GUEST_DIR}/${VM_NAME}"
    local disk_path="${guest_dir}/disk.qcow2"
    local cidata_path="${guest_dir}/cidata.iso"

    info "Creating VM disk"
    sudo mkdir -p "${guest_dir}"
    step "Copying base image to ${disk_path}"
    sudo cp "${cache_dir}/${image_name}" "${disk_path}"
    step "Resizing to ${VM_DISK}GB"
    sudo qemu-img resize "${disk_path}" "${VM_DISK}G"

    # ── Provisioning user-data script (processed by nuageinit) ───────
    # nuageinit runs BEFORE networking, so this script handles only local
    # operations: user creation, SSH keys, sudo config. Package installation
    # happens later via SSH once the VM is booted and has network.
    # The BASIC-CLOUDINIT image already has growfs_enable=YES and /firstboot.
    info "Creating cidata ISO"
    local cidata_tmp
    cidata_tmp=$(mktemp -d "${TMPDIR:-/tmp}/_cidata_${VM_NAME}.XXXXXX")

    cat > "${cidata_tmp}/meta-data" <<METAEOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METAEOF

    # Build provisioning shell script as user-data
    cat > "${cidata_tmp}/user-data" <<USEREOF
#!/bin/sh
# Provisioning script — processed by nuageinit on first boot

set -e

# Set hostname
hostname "${VM_NAME}"
sysrc hostname="${VM_NAME}"

# Configure root SSH keys
mkdir -p /root/.ssh
chmod 700 /root/.ssh
USEREOF

    # Append each SSH pubkey line (the file may contain multiple keys)
    echo "${ssh_pubkey}" | while IFS= read -r key; do
        [ -n "${key}" ] || continue
        printf 'echo "%s" >> /root/.ssh/authorized_keys\n' "${key}" >> "${cidata_tmp}/user-data"
    done

    cat >> "${cidata_tmp}/user-data" <<'USEREOF2'
chmod 600 /root/.ssh/authorized_keys

# Enable PermitRootLogin for key-only access
sed -i '' 's/^#PermitRootLogin no/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
USEREOF2

    if [ -n "${BUILD_USER}" ] && [ "${BUILD_USER}" != "root" ]; then
        cat >> "${cidata_tmp}/user-data" <<BUILDEOF

# Create build user
pw useradd -n "${BUILD_USER}" -m -G wheel -s /bin/sh
mkdir -p /home/${BUILD_USER}/.ssh
chmod 700 /home/${BUILD_USER}/.ssh
BUILDEOF

        echo "${ssh_pubkey}" | while IFS= read -r key; do
            [ -n "${key}" ] || continue
            printf 'echo "%s" >> /home/'"${BUILD_USER}"'/.ssh/authorized_keys\n' "${key}" >> "${cidata_tmp}/user-data"
        done

        cat >> "${cidata_tmp}/user-data" <<BUILDEOF2
chmod 600 /home/${BUILD_USER}/.ssh/authorized_keys
chown -R ${BUILD_USER}:${BUILD_USER} /home/${BUILD_USER}/.ssh
BUILDEOF2
    fi

    cat >> "${cidata_tmp}/user-data" <<'LOCALEOF'

echo "nuageinit provisioning complete"
LOCALEOF

    chmod +x "${cidata_tmp}/user-data"
    step "Generating cidata ISO"
    sudo genisoimage -output "${cidata_path}" -volid cidata -joliet -rock \
        "${cidata_tmp}/meta-data" "${cidata_tmp}/user-data" 2>/dev/null
    rm -rf "${cidata_tmp}"
    step "Created ${cidata_path}"

    # ── Boot the VM ──────────────────────────────────────────────────
    local os_variant="freebsd${FREEBSD_VERSION%%.*}.0"
    local console_log="${guest_dir}/console.log"

    info "Starting VM"
    sudo virt-install \
        --name "${VM_NAME}" \
        --memory "${VM_MEMORY}" \
        --vcpus "${VM_CPUS}" \
        --disk "path=${disk_path},bus=virtio" \
        --disk "path=${cidata_path},device=cdrom" \
        --network "network=${VM_NETWORK},model=virtio" \
        --os-variant "${os_variant}" \
        --import \
        --noautoconsole \
        --serial "file,path=${console_log}" \
        --graphics "vnc,listen=0.0.0.0" \
        --autostart
    step "VM defined and started (autostart enabled)"
    step "Console log: ${console_log}"

    # Wait for VM to get an IP
    info "Waiting for VM to boot and get an IP (this takes ~60s)"
    local vm_ip=""
    local wait_secs=0
    while [ -z "${vm_ip}" ] && [ ${wait_secs} -lt 180 ]; do
        sleep 5
        wait_secs=$((wait_secs + 5))
        # Try console log first — look for "bound to <ip>" from dhclient
        vm_ip=$(sudo grep -oE 'bound to [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${console_log}" 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1) || true
        # Fallback: ARP detection
        if [ -z "${vm_ip}" ]; then
            vm_ip=$(sudo virsh domifaddr "${VM_NAME}" --source arp 2>/dev/null \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true
        fi
        [ -z "${vm_ip}" ] && printf "." >&2
    done
    [ -n "${vm_ip}" ] && echo "" >&2

    if [ -z "${vm_ip}" ]; then
        warn "Could not detect VM IP address automatically."
        warn "The VM is running. Check manually:"
        warn "  sudo virsh domifaddr ${VM_NAME} --source arp"
        warn "Once known, set BUILD_HOST=root@<ip> and run:"
        warn "  opnsense-build.sh bootstrap"
        return 1
    fi
    step "VM IP address: ${vm_ip}"

    # Wait for SSH to become available
    ssh-keygen -R "${vm_ip}" >/dev/null 2>&1 || true
    info "Waiting for SSH"
    local ssh_wait=0
    while ! vm_ssh "root@${vm_ip}" "echo ok" >/dev/null 2>&1; do
        ssh_wait=$((ssh_wait + 5))
        if [ ${ssh_wait} -ge 300 ]; then
            warn "SSH to root@${vm_ip} not available after 300s."
            warn "Debug with: sudo virsh console ${VM_NAME}"
            return 1
        fi
        sleep 5
        printf "." >&2
    done
    echo "" >&2
    step "SSH accessible"

    # Install packages via SSH (nuageinit runs before networking,
    # so package installation must happen after boot)
    info "Installing packages"
    vm_ssh "root@${vm_ip}" "env ASSUME_ALWAYS_YES=yes pkg bootstrap -f && pkg update -f && pkg install -y git sudo" \
        || die "Package installation failed"
    step "Packages installed"

    # Configure sudo (needs sudo package installed first)
    vm_ssh "root@${vm_ip}" "grep -q '^%wheel ALL=(ALL) NOPASSWD: ALL' /usr/local/etc/sudoers 2>/dev/null || echo '%wheel ALL=(ALL) NOPASSWD: ALL' >> /usr/local/etc/sudoers"
    step "Sudo configured"

    # Verify
    echo ""
    info "Verifying build server"

    local uname_r
    uname_r=$(vm_ssh "root@${vm_ip}" "uname -r")
    step "FreeBSD ${uname_r}"

    # Verify packages installed
    if vm_ssh "root@${vm_ip}" "which sudo git" >/dev/null 2>&1; then
        step "Packages: git sudo installed"
    else
        warn "Packages not fully installed — check provisioning"
    fi

    # Check resources
    local disk_avail mem_gb ncpu
    disk_avail=$(vm_ssh "root@${vm_ip}" "df -g / | tail -1" | awk '{print $4}')
    mem_gb=$(vm_ssh "root@${vm_ip}" "sysctl -n hw.physmem" | awk '{printf "%d", $1/1073741824}')
    ncpu=$(vm_ssh "root@${vm_ip}" "sysctl -n hw.ncpu")

    step "Resources: ${ncpu} CPUs, ${mem_gb}GB RAM, ${disk_avail}GB disk free"

    if [ "${disk_avail}" -lt 40 ] 2>/dev/null; then
        warn "Only ${disk_avail}GB free — builds need 40GB+ (80GB+ recommended)"
    fi
    if [ "${mem_gb}" -lt 7 ] 2>/dev/null; then
        warn "Only ${mem_gb}GB RAM — builds need 8GB+"
    fi

    echo ""
    info "Build server ready: ${VM_NAME} at ${vm_ip}"
    step "${VM_CPUS} CPUs, ${VM_MEMORY}MB RAM, ${VM_DISK}GB disk"
    echo ""
    step "Add to your opnsense-build.conf:"
    if [ -n "${BUILD_USER}" ]; then
        step "  BUILD_HOST=${BUILD_USER}@${vm_ip}"
    else
        step "  BUILD_HOST=root@${vm_ip}"
    fi
    echo ""
    step "Next steps:"
    step "  opnsense-build.sh bootstrap"
    step "  opnsense-build.sh build"
}

# ── Delete ───────────────────────────────────────────────────────────

cmd_delete() {
    local name=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *)      die "Unknown option: $1" ;;
        esac
    done

    [ -n "${name}" ] || die "Usage: $(basename "$0") delete --name NAME"

    if ! sudo virsh dominfo "${name}" >/dev/null 2>&1; then
        die "VM '${name}' does not exist"
    fi

    info "Deleting VM: ${name}"

    # Stop if running
    local state
    state=$(sudo virsh domstate "${name}" 2>/dev/null) || true
    if [ "${state}" = "running" ]; then
        step "Stopping VM"
        sudo virsh destroy "${name}" 2>/dev/null || true
    fi

    # Find disk path before undefining
    local disk_dir=""
    local disk_path
    disk_path=$(sudo virsh domblklist "${name}" 2>/dev/null \
        | awk '/qcow2|disk/ {print $2}' | head -1) || true
    if [ -n "${disk_path}" ]; then
        disk_dir=$(dirname "${disk_path}")
    fi

    # Undefine the VM (remove from libvirt)
    step "Removing VM definition"
    sudo virsh undefine "${name}" --remove-all-storage 2>/dev/null \
        || sudo virsh undefine "${name}" 2>/dev/null

    # Clean up guest directory if it exists
    if [ -n "${disk_dir}" ] && [ -d "${disk_dir}" ]; then
        step "Removing ${disk_dir}"
        sudo rm -rf "${disk_dir}"
    fi

    info "VM '${name}' deleted"
}

# ── Main dispatch ────────────────────────────────────────────────────

[ $# -ge 1 ] || usage

COMMAND="$1"
shift

case "${COMMAND}" in
    create)           cmd_create "$@" ;;
    delete)           cmd_delete "$@" ;;
    help|--help|-h)   usage ;;
    *)                die "Unknown command: ${COMMAND}" ;;
esac
