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
# opnsense-build-server.sh — Build commands for the OPNsense build server
#
# Run this directly on the build server. It wraps common build operations
# so you don't need the workstation orchestrator for day-to-day builds.
#
# Lives in banzai-plugins/tools/ — check out the repo on the build server.
# Config: /etc/opnsense-build-server.conf (written by opnsense-build.sh bootstrap)
#
# Usage: opnsense-build-server.sh <command> [args...]
#

set -e

# ── Logging ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
step() { echo "    $*"; }
warn() { echo "WARNING: $*" >&2; }

# ── Configuration ────────────────────────────────────────────────────

CONF_FILE="${OPNSENSE_BUILD_SERVER_CONF:-/etc/opnsense-build-server.conf}"

load_config() {
    if [ -f "${CONF_FILE}" ]; then
        . "${CONF_FILE}"
    fi

    TOOLSDIR="${TOOLSDIR:-/usr/tools}"
    SERIES="${SERIES:-}"
    DEVICE="${DEVICE:-BANZAI}"
    VM_FORMAT="${VM_FORMAT:-qcow2}"

    [ -n "${SERIES}" ] || die "SERIES not set. Configure ${CONF_FILE} or set SERIES env var."
}

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  build [stage...]    Build VM image (base|kernel|ports|core|plugins|vm, default: all)
  status              Show build server state (repos, artifacts, resources)
  update              Pull latest code for all repos

Configuration:
  ${CONF_FILE}
  Override with OPNSENSE_BUILD_SERVER_CONF environment variable.

Environment variables: SERIES, DEVICE, VM_FORMAT, TOOLSDIR
EOF
    exit 1
}

# ── Commands ─────────────────────────────────────────────────────────

cmd_build() {
    local stages="$*"

    if [ -z "${stages}" ] || [ "${stages}" = "all" ]; then
        info "Building VM image (full build)"
        step "Running: make vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
        sudo make -C "${TOOLSDIR}" "vm-${VM_FORMAT}" "DEVICE=${DEVICE}" BATCH=yes
    else
        for stage in ${stages}; do
            case "${stage}" in
                base|kernel|ports|core|plugins)
                    info "Building stage: ${stage}"
                    step "Running: make ${stage} DEVICE=${DEVICE} BATCH=yes"
                    sudo make -C "${TOOLSDIR}" "${stage}" "DEVICE=${DEVICE}" BATCH=yes
                    ;;
                vm)
                    info "Building stage: vm-${VM_FORMAT}"
                    step "Running: make vm-${VM_FORMAT} DEVICE=${DEVICE} BATCH=yes"
                    sudo make -C "${TOOLSDIR}" "vm-${VM_FORMAT}" "DEVICE=${DEVICE}" BATCH=yes
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
    if [ -d "${images_dir}" ]; then
        step "Artifacts:"
        ls -lh "${images_dir}"/*.qcow2 "${images_dir}"/*.raw "${images_dir}"/*.img 2>/dev/null | while read -r line; do
            step "  ${line}"
        done
    fi
}

cmd_status() {
    info "Build server status"

    # FreeBSD version
    local uname_r
    uname_r=$(uname -r)
    step "FreeBSD: ${uname_r}"
    step "Series: ${SERIES}"

    # Repo status
    echo ""
    info "Repositories"
    local srcdir="${TOOLSDIR%/*}/src"
    local coredir="${TOOLSDIR%/*}/core"
    local pluginsdir="${TOOLSDIR%/*}/plugins"
    local portsdir="${TOOLSDIR%/*}/ports"
    for entry in "tools:${TOOLSDIR}" "src:${srcdir}" "core:${coredir}" "plugins:${pluginsdir}" "ports:${portsdir}"; do
        local name="${entry%%:*}"
        local dir="${entry#*:}"
        if [ -d "${dir}/.git" ]; then
            local branch commit
            branch=$(sudo git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="(unknown)"
            commit=$(sudo git -C "${dir}" log --oneline -1 2>/dev/null) || commit="(no commits)"
            step "${name} (${dir}): ${branch} — ${commit}"
        else
            step "${name} (${dir}): NOT CLONED"
        fi
    done

    # Series config
    echo ""
    info "Series configuration"
    if [ -d "${TOOLSDIR}/config/${SERIES}" ]; then
        step "config/${SERIES}/: exists"
    else
        step "config/${SERIES}/: MISSING"
    fi

    # Device config
    if [ -f "${TOOLSDIR}/device/${DEVICE}.conf" ]; then
        step "device/${DEVICE}.conf: exists"
    else
        step "device/${DEVICE}.conf: MISSING"
    fi

    # Build artifacts
    echo ""
    info "Build artifacts"
    local images_dir="/usr/local/opnsense/build/${SERIES}/amd64/images"
    if [ -d "${images_dir}" ]; then
        ls -lht "${images_dir}/" 2>/dev/null | head -10 | while read -r line; do
            step "${line}"
        done
    else
        step "No build artifacts found"
    fi

    # Disk space
    echo ""
    info "Resources"
    local disk_info
    disk_info=$(df -h / | tail -1 | awk '{print "Disk: " $4 " available of " $2}')
    step "${disk_info}"
    local mem_gb
    mem_gb=$(sysctl -n hw.physmem | awk '{printf "%d", $1/1073741824}')
    step "RAM: ${mem_gb}GB"
}

cmd_update() {
    info "Updating repositories for series ${SERIES}"
    sudo make -C "${TOOLSDIR}" update
    echo ""
    info "Update complete"
}

# ── Main dispatch ────────────────────────────────────────────────────

[ $# -ge 1 ] || usage

COMMAND="$1"
shift

case "${COMMAND}" in
    help|--help|-h) usage ;;
esac

load_config

case "${COMMAND}" in
    build)    cmd_build "$@" ;;
    status)   cmd_status "$@" ;;
    update)   cmd_update "$@" ;;
    *)        die "Unknown command: ${COMMAND}" ;;
esac
