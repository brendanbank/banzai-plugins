#!/bin/sh
#
# opnsense-build.sh — Build server automation for OPNsense VM images
#
# Automates the full lifecycle: create a FreeBSD VM, provision it,
# bootstrap OPNsense repos, build VM images, and deploy to KVM guests.
#
# Usage: opnsense-build.sh <command> [args...]
#

set -e

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

. "${TOOLS_DIR}/lib/common.sh"

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  create-vm           Create a FreeBSD VM on the KVM host and provision it
  provision           Provision an existing FreeBSD machine as a build server
  bootstrap           Clone OPNsense repos and configure for a release series
  update              Pull latest code for all repos on the build server
  sync-device         Sync device config to the build server
  build [stage...]    Build VM image (base|kernel|ports|core|plugins|vm, default: all)
  status              Show build server state
  deploy [--guest X]  Deploy built image to KVM guest
  series <series>     Switch repos to a different release series

Configuration:
  Copy opnsense-build.conf.sample to opnsense-build.conf and edit it.
  Override location with OPNSENSE_BUILD_CONF environment variable.
EOF
    exit 1
}

# ── Provisioning helper ─────────────────────────────────────────────
# Shared by cmd_provision and cmd_create_vm.

_provision_server() {
    info "Provisioning ${BUILD_HOST}"

    # Test SSH
    step "Testing SSH connectivity"
    remote "echo ok" >/dev/null 2>&1 || die "Cannot SSH to ${BUILD_HOST}"
    step "Connected"

    # Detect OS
    local uname_r os_name
    uname_r=$(remote "uname -r")
    os_name=$(remote "uname -s")
    [ "${os_name}" = "FreeBSD" ] || die "Expected FreeBSD, got ${os_name}"
    step "FreeBSD ${uname_r}"

    # Detect if root or unprivileged
    local remote_user
    remote_user=$(remote "whoami")

    # Bootstrap pkg
    step "Bootstrapping pkg"
    if [ "${remote_user}" = "root" ]; then
        remote "env ASSUME_ALWAYS_YES=yes pkg bootstrap -f" 2>/dev/null || true
    else
        remote "sudo env ASSUME_ALWAYS_YES=yes pkg bootstrap -f" 2>/dev/null || true
    fi

    # Install packages
    step "Installing packages: git sudo"
    if [ "${remote_user}" = "root" ]; then
        remote "pkg install -y git sudo" || die "Failed to install packages"
    else
        remote "sudo pkg install -y git sudo" || die "Failed to install packages"
    fi

    # Create build user if connected as root and BUILD_USER is set
    if [ "${remote_user}" = "root" ] && [ -n "${BUILD_USER}" ]; then
        if remote "pw user show ${BUILD_USER}" >/dev/null 2>&1; then
            step "User ${BUILD_USER} already exists"
        else
            step "Creating user ${BUILD_USER}"
            remote "pw useradd ${BUILD_USER} -m -G wheel -s /bin/sh"
        fi

        # Ensure wheel group membership
        remote "pw groupmod wheel -m ${BUILD_USER}" 2>/dev/null || true

        # Copy SSH authorized keys to the new user
        step "Setting up SSH keys for ${BUILD_USER}"
        remote "mkdir -p /home/${BUILD_USER}/.ssh && \
            chmod 700 /home/${BUILD_USER}/.ssh && \
            cp /root/.ssh/authorized_keys /home/${BUILD_USER}/.ssh/authorized_keys && \
            chown -R ${BUILD_USER}:${BUILD_USER} /home/${BUILD_USER}/.ssh && \
            chmod 600 /home/${BUILD_USER}/.ssh/authorized_keys"
        step "SSH keys copied from root to ${BUILD_USER}"
    fi

    # Configure sudo NOPASSWD for wheel group
    step "Configuring passwordless sudo for wheel group"
    if [ "${remote_user}" = "root" ]; then
        remote "sh -c '
            if ! grep -q \"^%wheel ALL=(ALL) NOPASSWD: ALL\" /usr/local/etc/sudoers 2>/dev/null; then
                echo \"%wheel ALL=(ALL) NOPASSWD: ALL\" >> /usr/local/etc/sudoers
            fi'"
    else
        remote "sudo sh -c '
            if ! grep -q \"^%wheel ALL=(ALL) NOPASSWD: ALL\" /usr/local/etc/sudoers 2>/dev/null; then
                echo \"%wheel ALL=(ALL) NOPASSWD: ALL\" >> /usr/local/etc/sudoers
            fi'"
    fi
    step "wheel group has NOPASSWD sudo"

    # Check resources
    local disk_avail mem_gb ncpu
    disk_avail=$(remote "df -g / | tail -1" | awk '{print $4}')
    mem_gb=$(remote "sysctl -n hw.physmem" | awk '{printf "%d", $1/1073741824}')
    ncpu=$(remote "sysctl -n hw.ncpu")

    step "Resources: ${ncpu} CPUs, ${mem_gb}GB RAM, ${disk_avail}GB disk free"

    if [ "${disk_avail}" -lt 40 ] 2>/dev/null; then
        warn "Only ${disk_avail}GB free — builds need 40GB+ (80GB+ recommended)"
    fi
    if [ "${mem_gb}" -lt 7 ] 2>/dev/null; then
        warn "Only ${mem_gb}GB RAM — builds need 8GB+"
    fi

    echo ""
    info "Provisioning complete"
    if [ -n "${BUILD_USER}" ] && [ "${remote_user}" = "root" ]; then
        step "User ${BUILD_USER} created with passwordless sudo"
        step "Set BUILD_HOST to use ${BUILD_USER} for subsequent commands"
    fi
}

# ── Subcommands ──────────────────────────────────────────────────────

cmd_create_vm() {
    validate_kvm_host

    info "Creating build VM: ${BUILD_VM_NAME}"
    step "${BUILD_VM_CPUS} CPUs, ${BUILD_VM_MEMORY}MB RAM, ${BUILD_VM_DISK}GB disk"
    step "FreeBSD ${FREEBSD_VERSION}, network: ${BUILD_VM_NETWORK}"

    # Check required tools on KVM host
    info "Checking KVM host prerequisites"
    local missing=""
    for tool in virsh virt-install qemu-img genisoimage wget xz; do
        if ! kvm_ssh "which ${tool}" >/dev/null 2>&1; then
            missing="${missing} ${tool}"
        fi
    done
    if [ -n "${missing}" ]; then
        die "Missing tools on ${KVM_HOST}:${missing}
Install with: apt install libvirt-daemon-system virtinst qemu-utils genisoimage wget xz-utils"
    fi
    step "All required tools available"

    # Check if VM already exists
    if kvm_sudo "virsh dominfo ${BUILD_VM_NAME}" >/dev/null 2>&1; then
        die "VM '${BUILD_VM_NAME}' already exists on ${KVM_HOST}. Remove it first or choose a different name."
    fi

    # SSH public key (required for cloud-init)
    local pubkey_file
    pubkey_file=$(find_ssh_pubkey)
    local ssh_pubkey
    ssh_pubkey=$(cat "${pubkey_file}")
    case "${pubkey_file}" in
        */opnsense-build-pubkey.*) rm -f "${pubkey_file}" ;;
    esac

    # Download FreeBSD BASIC-CLOUDINIT image
    # This variant includes nuageinit which processes cloud-init NoCloud data
    local image_name="FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2"
    local image_url="https://download.freebsd.org/releases/VM-IMAGES/${FREEBSD_VERSION}-RELEASE/amd64/Latest/${image_name}.xz"
    local cache_dir="/var/cache/freebsd-images"

    info "FreeBSD ${FREEBSD_VERSION} BASIC-CLOUDINIT image"
    kvm_sudo "mkdir -p ${cache_dir}"

    if kvm_ssh "sudo test -f ${cache_dir}/${image_name}"; then
        step "Using cached image: ${cache_dir}/${image_name}"
    else
        if kvm_ssh "sudo test -f ${cache_dir}/${image_name}.xz"; then
            step "Using cached compressed image"
        else
            step "Downloading ${image_url}"
            kvm_sudo "wget -q --show-progress -O ${cache_dir}/${image_name}.xz '${image_url}'" \
                || die "Failed to download FreeBSD image"
        fi
        step "Decompressing (this may take a minute)..."
        kvm_sudo "xz -dk ${cache_dir}/${image_name}.xz"
    fi

    # Create guest directory and disk
    local guest_dir="${KVM_GUEST_DIR}/${BUILD_VM_NAME}"
    local disk_path="${guest_dir}/disk.qcow2"
    local cidata_path="${guest_dir}/cidata.iso"

    info "Creating VM disk"
    kvm_sudo "mkdir -p ${guest_dir}"
    step "Copying base image to ${disk_path}"
    kvm_sudo "cp ${cache_dir}/${image_name} ${disk_path}"
    step "Resizing to ${BUILD_VM_DISK}GB"
    kvm_sudo "qemu-img resize ${disk_path} ${BUILD_VM_DISK}G"

    # Create cloud-init NoCloud ISO
    # nuageinit on FreeBSD reads from a CD-ROM labeled "cidata"
    # We use a shell script for user-data (not cloud-config) because
    # FreeBSD 14.3 nuageinit doesn't support runcmd/write_files/packages.
    info "Creating cloud-init cidata ISO"
    local cidata_tmp="/tmp/_cidata_${BUILD_VM_NAME}"
    kvm_ssh "mkdir -p ${cidata_tmp}"

    # meta-data (required, can be minimal)
    kvm_ssh "cat > ${cidata_tmp}/meta-data" <<METAEOF
instance-id: ${BUILD_VM_NAME}
local-hostname: ${BUILD_VM_NAME}
METAEOF

    # user-data as a shell script
    # This runs on first boot and sets up root SSH, build user, sudo, etc.
    local user_data_build_user=""
    if [ -n "${BUILD_USER}" ] && [ "${BUILD_USER}" != "root" ]; then
        user_data_build_user="
# Create build user
if ! pw user show ${BUILD_USER} >/dev/null 2>&1; then
    pw useradd ${BUILD_USER} -m -G wheel -s /bin/sh
fi
pw groupmod wheel -m ${BUILD_USER} 2>/dev/null || true
mkdir -p /home/${BUILD_USER}/.ssh
chmod 700 /home/${BUILD_USER}/.ssh
echo '${ssh_pubkey}' > /home/${BUILD_USER}/.ssh/authorized_keys
chmod 600 /home/${BUILD_USER}/.ssh/authorized_keys
chown -R ${BUILD_USER}:${BUILD_USER} /home/${BUILD_USER}/.ssh"
    fi

    kvm_ssh "cat > ${cidata_tmp}/user-data" <<USEREOF
#!/bin/sh
# Cloud-init user-data script for build server provisioning

# Set up root SSH access
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo '${ssh_pubkey}' > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Enable root SSH login with key only
sed -i '' 's/^#PermitRootLogin no/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
service sshd restart
${user_data_build_user}

# Install sudo and configure NOPASSWD for wheel
# pkg bootstrap + upgrade first — fresh images have an old pkg that needs
# to self-upgrade before it can install anything.
env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
pkg update -f
pkg upgrade -y
pkg install -y git sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' >> /usr/local/etc/sudoers

# Grow filesystem to fill disk
growfs -y /
USEREOF
    kvm_ssh "chmod +x ${cidata_tmp}/user-data"

    # Generate the ISO
    step "Generating cidata ISO"
    kvm_sudo "genisoimage -output ${cidata_path} -volid cidata -joliet -rock ${cidata_tmp}/meta-data ${cidata_tmp}/user-data" \
        2>/dev/null
    kvm_ssh "rm -rf ${cidata_tmp}"
    step "Created ${cidata_path}"

    # Determine os-variant for virt-install
    local os_variant="freebsd${FREEBSD_VERSION%%.*}.0"

    # Create and start VM with cloud-init ISO attached
    # Serial console output is logged to a file for debugging boot issues.
    local console_log="${guest_dir}/console.log"
    info "Starting VM"
    kvm_sudo "virt-install \
        --name ${BUILD_VM_NAME} \
        --memory ${BUILD_VM_MEMORY} \
        --vcpus ${BUILD_VM_CPUS} \
        --disk path=${disk_path},bus=virtio \
        --disk path=${cidata_path},device=cdrom \
        --network network=${BUILD_VM_NETWORK},model=virtio \
        --os-variant ${os_variant} \
        --import \
        --noautoconsole \
        --serial file,path=${console_log} \
        --graphics vnc,listen=0.0.0.0"
    step "VM defined and started"
    step "Console log: ${KVM_HOST}:${console_log}"

    # Wait for VM to get an IP
    # Detection method: parse the serial console log for the DHCP lease.
    # Fallback: ARP-based detection (requires host to have communicated with VM).
    info "Waiting for VM to boot and get an IP (this takes ~60s)"
    local vm_ip=""
    local wait_secs=0
    while [ -z "${vm_ip}" ] && [ ${wait_secs} -lt 180 ]; do
        sleep 5
        wait_secs=$((wait_secs + 5))
        # Try console log first — look for "bound to <ip>" from dhclient
        vm_ip=$(kvm_ssh "sudo grep -oE 'bound to [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' ${console_log} 2>/dev/null" \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1) || true
        # Fallback: ARP detection (ping broadcast to populate ARP table)
        if [ -z "${vm_ip}" ]; then
            vm_ip=$(kvm_sudo "virsh domifaddr ${BUILD_VM_NAME} --source arp" 2>/dev/null \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true
        fi
        [ -z "${vm_ip}" ] && printf "." >&2
    done
    [ -n "${vm_ip}" ] && echo "" >&2

    if [ -z "${vm_ip}" ]; then
        warn "Could not detect VM IP address automatically."
        warn "The VM is running. Check manually:"
        warn "  ssh ${KVM_HOST} 'sudo virsh domifaddr ${BUILD_VM_NAME} --source arp'"
        warn "Once known, set BUILD_HOST=root@<ip> and run:"
        warn "  $(basename "$0") provision"
        return 1
    fi
    step "VM IP address: ${vm_ip}"

    # Wait for SSH to become available
    # The user-data script runs on first boot: installs packages, configures
    # SSH, creates users. This can take 2-3 minutes.
    # Clear any stale known_hosts entry (new VM = new host keys).
    ssh-keygen -R "${vm_ip}" >/dev/null 2>&1 || true
    info "Waiting for SSH (user-data script is configuring the VM)"
    local ssh_wait=0
    while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
            "root@${vm_ip}" "echo ok" >/dev/null 2>&1; do
        ssh_wait=$((ssh_wait + 5))
        if [ ${ssh_wait} -ge 300 ]; then
            warn "SSH to root@${vm_ip} not available after 300s."
            warn "Debug with: ssh ${KVM_HOST} 'sudo virsh console ${BUILD_VM_NAME}'"
            warn "Once SSH works, set BUILD_HOST=root@${vm_ip} and run:"
            warn "  $(basename "$0") provision"
            return 1
        fi
        sleep 5
        printf "." >&2
    done
    echo "" >&2
    step "SSH accessible as root"

    # Run provisioning for resource checks and any remaining setup
    echo ""
    BUILD_HOST="root@${vm_ip}"
    _provision_server

    echo ""
    info "Build server ready: ${BUILD_VM_NAME} at ${vm_ip}"
    step "${BUILD_VM_CPUS} CPUs, ${BUILD_VM_MEMORY}MB RAM, ${BUILD_VM_DISK}GB disk"
    echo ""
    step "Add to your opnsense-build.conf:"
    if [ -n "${BUILD_USER}" ]; then
        step "  BUILD_HOST=${BUILD_USER}@${vm_ip}"
    else
        step "  BUILD_HOST=root@${vm_ip}"
    fi
    echo ""
    step "Next steps:"
    step "  $(basename "$0") bootstrap"
    step "  $(basename "$0") build"
}

cmd_provision() {
    validate_build_host
    _provision_server

    step "Next: $(basename "$0") bootstrap"
}

cmd_bootstrap() {
    validate_build_host
    info "Bootstrapping build server for series ${SERIES}"
    test_ssh

    # Verify FreeBSD version
    local uname_r
    uname_r=$(remote "uname -r")
    step "FreeBSD version: ${uname_r}"

    # Clone tools repo first (needed for make update)
    info "Cloning tools repository"
    remote_git_clone "${GIT_TOOLS}" "${REMOTE_TOOLSDIR}" "master"

    # Verify series config exists in tools
    if ! remote "test -d ${REMOTE_TOOLSDIR}/config/${SERIES}"; then
        die "config/${SERIES}/ does not exist in tools repo. This series is not available yet."
    fi
    step "Found config/${SERIES}/ in tools"

    # Use the tools repo's own 'make update' to clone and checkout all repos.
    # This ensures correct git URLs (all from github.com/opnsense/*) and
    # branch names (stable/<series> for src/core/plugins, master for ports/tools).
    info "Cloning and updating repositories via 'make update'"
    remote_sudo "make -C ${REMOTE_TOOLSDIR} update"

    # Sync device config
    _sync_device_conf

    echo ""
    info "Bootstrap complete for series ${SERIES}"
    step "Next: $(basename "$0") build"
}

cmd_update() {
    validate_build_host
    info "Updating repositories for series ${SERIES}"
    test_ssh

    # Use the tools repo's 'make update' which handles all repos,
    # correct branches, and git URLs.
    remote_sudo "make -C ${REMOTE_TOOLSDIR} update"

    echo ""
    info "Update complete"
}

cmd_sync_device() {
    validate_build_host
    info "Syncing device config"
    test_ssh
    _sync_device_conf
    echo ""
    info "Device config synced"
}

_sync_device_conf() {
    # Resolve device config path (relative to tools dir)
    local conf_path="${DEVICE_CONF}"
    if [ "${conf_path#/}" = "${conf_path}" ]; then
        # Relative path — resolve from tools dir
        conf_path="${TOOLS_DIR}/${conf_path}"
    fi

    [ -f "${conf_path}" ] || die "Device config not found: ${conf_path}"

    local conf_name
    conf_name=$(basename "${conf_path}")
    step "Syncing ${conf_name} to ${BUILD_HOST}:${REMOTE_TOOLSDIR}/device/"

    scp_to "${conf_path}" "/tmp/${conf_name}"
    remote_sudo "mkdir -p ${REMOTE_TOOLSDIR}/device"
    remote_sudo "mv /tmp/${conf_name} ${REMOTE_TOOLSDIR}/device/${conf_name}"
    remote_sudo "chown root:wheel ${REMOTE_TOOLSDIR}/device/${conf_name}"
    step "Done"
}

cmd_build() {
    validate_build_host
    local stages="$*"
    test_ssh

    if [ -z "${stages}" ] || [ "${stages}" = "all" ]; then
        info "Building VM image (full build)"
        step "Running: make vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
        remote_sudo "make -C ${REMOTE_TOOLSDIR} vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
    else
        for stage in ${stages}; do
            case "${stage}" in
                base|kernel|ports|core|plugins)
                    info "Building stage: ${stage}"
                    step "Running: make ${stage} DEVICE=${DEVICE} BATCH=yes"
                    remote_sudo "make -C ${REMOTE_TOOLSDIR} ${stage} DEVICE=${DEVICE} BATCH=yes"
                    ;;
                vm)
                    info "Building stage: vm-${VM_FORMAT}"
                    step "Running: make vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
                    remote_sudo "make -C ${REMOTE_TOOLSDIR} vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
                    ;;
                *)
                    die "Unknown build stage: ${stage} (valid: base kernel ports core plugins vm all)"
                    ;;
            esac
        done
    fi

    echo ""
    info "Build complete"

    # Show resulting artifacts
    local images_dir="/usr/local/opnsense/build/${SERIES}/amd64/images"
    if remote "test -d ${images_dir}"; then
        step "Artifacts:"
        remote "ls -lh ${images_dir}/*.qcow2 ${images_dir}/*.raw ${images_dir}/*.img 2>/dev/null" | while read -r line; do
            step "  ${line}"
        done
    fi
}

cmd_status() {
    validate_build_host
    info "Build server status (${BUILD_HOST})"
    test_ssh

    # FreeBSD version
    local uname_r
    uname_r=$(remote "uname -r")
    step "FreeBSD: ${uname_r}"

    # Repo status
    echo ""
    info "Repositories"
    local repos="tools:${REMOTE_TOOLSDIR} src:${REMOTE_SRCDIR} core:${REMOTE_COREDIR} plugins:${REMOTE_PLUGINSDIR} ports:${REMOTE_PORTSDIR}"
    for entry in ${repos}; do
        local name="${entry%%:*}"
        local dir="${entry#*:}"
        if remote "test -d ${dir}/.git"; then
            local branch commit
            branch=$(remote_git_branch "${dir}")
            commit=$(remote_git_log1 "${dir}")
            step "${name} (${dir}): ${branch} — ${commit}"
        else
            step "${name} (${dir}): NOT CLONED"
        fi
    done

    # Series config
    echo ""
    info "Series configuration"
    if remote "test -d ${REMOTE_TOOLSDIR}/config/${SERIES}"; then
        step "config/${SERIES}/: exists"
    else
        step "config/${SERIES}/: MISSING"
    fi

    # Device config
    if remote "test -f ${REMOTE_TOOLSDIR}/device/${DEVICE}.conf"; then
        step "device/${DEVICE}.conf: exists"
    else
        step "device/${DEVICE}.conf: MISSING"
    fi

    # Build artifacts
    echo ""
    info "Build artifacts"
    local images_dir="/usr/local/opnsense/build/${SERIES}/amd64/images"
    if remote "test -d ${images_dir}"; then
        remote "ls -lht ${images_dir}/ 2>/dev/null | head -10" | while read -r line; do
            step "${line}"
        done
    else
        step "No build artifacts found"
    fi

    # Disk space
    echo ""
    info "Resources"
    local disk_info
    disk_info=$(remote "df -h / | tail -1 | awk '{print \"Disk: \" \$4 \" available of \" \$2}'")
    step "${disk_info}"
    local mem_gb
    mem_gb=$(remote "sysctl -n hw.physmem | awk '{printf \"%d\", \$1/1073741824}'")
    step "RAM: ${mem_gb}GB"
}

cmd_deploy() {
    validate_build_host
    validate_kvm_host
    local guest="${KVM_GUEST_NAME}"

    # Parse --guest flag
    while [ $# -gt 0 ]; do
        case "$1" in
            --guest)
                guest="$2"
                shift 2
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    [ -n "${guest}" ] || die "No guest name specified. Use --guest NAME or set KVM_GUEST_NAME in config."

    info "Deploying to ${guest} via ${KVM_HOST}"
    test_ssh

    # Find most recent image
    local images_dir="/usr/local/opnsense/build/${SERIES}/amd64/images"
    local image_path
    image_path=$(remote "ls -t ${images_dir}/*.qcow2 2>/dev/null | head -1")
    [ -n "${image_path}" ] || die "No .qcow2 image found in ${images_dir}/"

    local image_name
    image_name=$(basename "${image_path}")
    step "Image: ${image_name}"

    local dest="${KVM_GUEST_DIR}/${guest}/disk.qcow2"
    step "Destination: ${KVM_HOST}:${dest}"

    # Stop the guest VM before overwriting its disk
    if kvm_sudo "virsh dominfo ${guest}" >/dev/null 2>&1; then
        step "Stopping ${guest}"
        kvm_sudo "virsh destroy ${guest}" 2>/dev/null || true
    fi

    # Copy image via KVM host (both VMs are typically on the same host).
    # Use -A to forward SSH agent so the KVM host can authenticate to the build host.
    info "Copying image to ${guest}"
    ssh -A "${KVM_HOST}" "scp ${BUILD_HOST}:${image_path} ${dest}"

    # Start the guest VM
    step "Starting ${guest}"
    kvm_sudo "virsh start ${guest}"

    echo ""
    info "Deploy complete"
    step "Image deployed to ${guest}"
    step "Note: New images regenerate SSH host keys."
    step "Run: ssh-keygen -R <guest-ip>"
}

cmd_series() {
    validate_build_host
    local new_series="$1"
    [ -n "${new_series}" ] || die "Usage: $(basename "$0") series <series>"

    info "Switching to series ${new_series}"
    test_ssh

    # Fetch tools first and verify the new series config exists
    remote_sudo "git -C ${REMOTE_TOOLSDIR} fetch --tags --prune origin"
    if ! remote "test -d ${REMOTE_TOOLSDIR}/config/${new_series}"; then
        die "config/${new_series}/ does not exist in tools repo. This series may not be available yet."
    fi
    step "Found config/${new_series}/ in tools"

    # Use 'make update' with SETTINGS override to switch all repos
    # to the new series branches.
    info "Updating repositories for series ${new_series}"
    remote_sudo "make -C ${REMOTE_TOOLSDIR} update SETTINGS=${new_series}"

    echo ""
    info "Switched to series ${new_series}"
    step "Update SERIES=${new_series} in your opnsense-build.conf"
}

# ── Main dispatch ────────────────────────────────────────────────────

[ $# -ge 1 ] || usage

COMMAND="$1"
shift

# Help doesn't need config
case "${COMMAND}" in
    help|--help|-h) usage ;;
esac

# Load config for all other commands
load_config
validate_config

case "${COMMAND}" in
    create-vm)    cmd_create_vm "$@" ;;
    provision)    cmd_provision "$@" ;;
    bootstrap)    cmd_bootstrap "$@" ;;
    update)       cmd_update "$@" ;;
    sync-device)  cmd_sync_device "$@" ;;
    build)        cmd_build "$@" ;;
    status)       cmd_status "$@" ;;
    deploy)       cmd_deploy "$@" ;;
    series)       cmd_series "$@" ;;
    *)            die "Unknown command: ${COMMAND}" ;;
esac
