#!/bin/sh
#
# common.sh — Shared helpers for opnsense-build.sh
#
# Sourced by the main script. Provides config loading, SSH wrappers,
# logging, and remote git operations.
#

# ── Logging ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
step() { echo "    $*"; }
warn() { echo "WARNING: $*" >&2; }

# ── Configuration ────────────────────────────────────────────────────

load_config() {
    local conf=""

    if [ -n "${OPNSENSE_BUILD_CONF}" ]; then
        conf="${OPNSENSE_BUILD_CONF}"
    elif [ -f "${TOOLS_DIR}/opnsense-build.conf" ]; then
        conf="${TOOLS_DIR}/opnsense-build.conf"
    elif [ -f "${HOME}/.config/opnsense-build.conf" ]; then
        conf="${HOME}/.config/opnsense-build.conf"
    fi

    if [ -n "${conf}" ]; then
        [ -f "${conf}" ] || die "Config file not found: ${conf}"
        step "Loading config: ${conf}"
        . "${conf}"
    else
        die "No config file found. Copy opnsense-build.conf.sample to opnsense-build.conf and edit it."
    fi

    # Apply defaults for optional variables
    REMOTE_TOOLSDIR="${REMOTE_TOOLSDIR:-/usr/tools}"
    REMOTE_SRCDIR="${REMOTE_SRCDIR:-/usr/src}"
    REMOTE_COREDIR="${REMOTE_COREDIR:-/usr/core}"
    REMOTE_PLUGINSDIR="${REMOTE_PLUGINSDIR:-/usr/plugins}"
    REMOTE_PORTSDIR="${REMOTE_PORTSDIR:-/usr/ports}"

    GIT_TOOLS="${GIT_TOOLS:-https://github.com/opnsense/tools.git}"
    GIT_CORE="${GIT_CORE:-https://github.com/opnsense/core.git}"
    GIT_PLUGINS="${GIT_PLUGINS:-https://github.com/opnsense/plugins.git}"
    GIT_SRC="${GIT_SRC:-https://git.FreeBSD.org/src.git}"
    GIT_PORTS="${GIT_PORTS:-https://git.FreeBSD.org/ports.git}"

    DEVICE_CONF="${DEVICE_CONF:-../../BANZAI.conf}"
    DEVICE="${DEVICE:-BANZAI}"
    VM_FORMAT="${VM_FORMAT:-qcow2}"

    # VM creation defaults
    BUILD_VM_NAME="${BUILD_VM_NAME:-fbsd-build}"
    BUILD_VM_CPUS="${BUILD_VM_CPUS:-4}"
    BUILD_VM_MEMORY="${BUILD_VM_MEMORY:-16384}"
    BUILD_VM_DISK="${BUILD_VM_DISK:-100}"
    BUILD_VM_NETWORK="${BUILD_VM_NETWORK:-default}"
    FREEBSD_VERSION="${FREEBSD_VERSION:-14.3}"
    KVM_GUEST_DIR="${KVM_GUEST_DIR:-/var/vms/guests}"
}

validate_config() {
    [ -n "${SERIES}" ] || die "SERIES not set in config"
}

validate_build_host() {
    [ -n "${BUILD_HOST}" ] || die "BUILD_HOST not set in config"
}

validate_kvm_host() {
    [ -n "${KVM_HOST}" ] || die "KVM_HOST not set in config"
}

# ── SSH ──────────────────────────────────────────────────────────────

remote() {
    ssh "${BUILD_HOST}" "$@"
}

remote_sudo() {
    ssh "${BUILD_HOST}" "sudo $*"
}

scp_to() {
    scp -q "$1" "${BUILD_HOST}:$2"
}

scp_from() {
    scp -q "${BUILD_HOST}:$1" "$2"
}

test_ssh() {
    info "Testing SSH connectivity to ${BUILD_HOST}"
    remote "echo ok" >/dev/null 2>&1 || die "Cannot connect to ${BUILD_HOST} via SSH"
    step "Connected to ${BUILD_HOST}"
}

# SSH to KVM host
kvm_ssh() {
    ssh "${KVM_HOST}" "$@"
}

kvm_sudo() {
    ssh "${KVM_HOST}" "sudo $*"
}

# ── SSH key discovery ────────────────────────────────────────────────

# Returns a file path containing the SSH public key.
# SSH_PUBKEY can be a key string ("ssh-rsa ...") or a file path.
find_ssh_pubkey() {
    local key="${SSH_PUBKEY}"
    [ -n "${key}" ] || die "SSH_PUBKEY not set in config."

    # If it looks like a key string, write to a temp file
    case "${key}" in
        ssh-*|ecdsa-*)
            local tmpkey
            tmpkey=$(mktemp "${TMPDIR:-/tmp}/opnsense-build-pubkey.XXXXXX")
            echo "${key}" > "${tmpkey}"
            echo "${tmpkey}"
            return
            ;;
    esac

    # Otherwise treat as file path
    case "${key}" in
        "~/"*) key="${HOME}/${key#\~/}" ;;
    esac
    [ -f "${key}" ] || die "SSH_PUBKEY file not found: ${key}"
    echo "${key}"
}

# ── Remote git operations ────────────────────────────────────────────
# All /usr repos are root-owned, so git commands need sudo.

remote_git_clone() {
    local url="$1" dir="$2" branch="$3"

    if remote "test -d ${dir}/.git"; then
        step "${dir} already exists, skipping clone"
        return 0
    fi

    step "Cloning ${url} → ${dir}"
    if [ -n "${branch}" ]; then
        remote_sudo "git clone -b ${branch} ${url} ${dir}"
    else
        remote_sudo "git clone ${url} ${dir}"
    fi
}

remote_git_fetch() {
    local dir="$1"
    step "Fetching ${dir}"
    remote_sudo "git -C ${dir} fetch --tags --prune origin"
}

remote_git_checkout() {
    local dir="$1" branch="$2"
    step "Checking out ${branch} in ${dir}"
    remote_sudo "git -C ${dir} checkout ${branch}"
    remote_sudo "git -C ${dir} pull --ff-only origin ${branch}" 2>/dev/null || true
}

remote_git_branch() {
    local dir="$1"
    remote "sudo git -C ${dir} rev-parse --abbrev-ref HEAD 2>/dev/null" || echo "(unknown)"
}

remote_git_log1() {
    local dir="$1"
    remote "sudo git -C ${dir} log --oneline -1 2>/dev/null" || echo "(no commits)"
}
