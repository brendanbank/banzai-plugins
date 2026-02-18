#!/bin/sh
#
# opnsense-build.sh — Build server orchestrator for OPNsense VM images
#
# Orchestrates builds on a remote FreeBSD build server via SSH:
# bootstrap OPNsense repos, build VM images, and deploy to KVM guests.
#
# For VM creation, see create-build-vm.sh (runs locally on the KVM host).
# For on-server builds, see opnsense-build-server.sh (runs on the build server).
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

See also:
  create-build-vm.sh        Create a FreeBSD VM on a KVM host
  opnsense-build-server.sh  Run builds directly on the build server
EOF
    exit 1
}

# ── Subcommands ──────────────────────────────────────────────────────

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

    # Sync build server script and write config
    _sync_server_script

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

_sync_server_script() {
    # Write server-side config
    step "Writing /etc/opnsense-build-server.conf"
    remote "cat > /tmp/opnsense-build-server.conf" <<EOF
# opnsense-build-server.conf — written by opnsense-build.sh bootstrap
SERIES=${SERIES}
DEVICE=${DEVICE}
VM_FORMAT=${VM_FORMAT}
TOOLSDIR=${REMOTE_TOOLSDIR}
EOF
    remote_sudo "mv /tmp/opnsense-build-server.conf /etc/opnsense-build-server.conf"
    remote_sudo "chown root:wheel /etc/opnsense-build-server.conf"
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

    # Update server-side config with new series
    step "Updating /etc/opnsense-build-server.conf"
    remote "cat > /tmp/opnsense-build-server.conf" <<EOF
# opnsense-build-server.conf — written by opnsense-build.sh series
SERIES=${new_series}
DEVICE=${DEVICE}
VM_FORMAT=${VM_FORMAT}
TOOLSDIR=${REMOTE_TOOLSDIR}
EOF
    remote_sudo "mv /tmp/opnsense-build-server.conf /etc/opnsense-build-server.conf"
    remote_sudo "chown root:wheel /etc/opnsense-build-server.conf"

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
    bootstrap)    cmd_bootstrap "$@" ;;
    update)       cmd_update "$@" ;;
    sync-device)  cmd_sync_device "$@" ;;
    build)        cmd_build "$@" ;;
    status)       cmd_status "$@" ;;
    deploy)       cmd_deploy "$@" ;;
    series)       cmd_series "$@" ;;
    *)            die "Unknown command: ${COMMAND}" ;;
esac
