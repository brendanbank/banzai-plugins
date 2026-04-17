#!/bin/sh

# Copyright (C) 2025 Brendan Bank
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
# Build all OPNsense plugin packages in banzai-plugins.
#
# Usage: ./build.sh [--test] [--dev] <hostname>
#
# The build happens on a FreeBSD/OPNsense host via SSH. Build infrastructure
# comes from the opnsense-plugins/ submodule and is synced to the remote.
#
# After building, packages are downloaded to dist/ and the GitHub Pages pkg
# repo in docs/${ABI}/${SERIES}/repo/ is updated with signed packages.
# Signing uses the YubiKey PIV slot via piv-sign-agent.py: the agent listens
# on a Unix socket locally and the socket is forwarded to the remote via SSH -R.
#
# Options:
#   --test    Build only; skip repo signing, docs, and GitHub Pages update.
#   --dev     Build -devel packages and publish to the dev repo path.
#             Devel packages have an os-<name>-devel suffix, PLUGIN_TIER=4,
#             and conflict with their stable counterpart. On the firewall,
#             enable the dev repo to install them via the firmware UI:
#               sudo sed -i '' 's/enabled: no/enabled: yes/' \
#                 /usr/local/etc/pkg/repos/banzai-plugins-dev.conf
#               sudo pkg update
#

set -e

TEST_MODE=0
DEV_MODE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --test) TEST_MODE=1; shift ;;
        --dev)  DEV_MODE=1; shift ;;
        *)      break ;;
    esac
done

FIREWALL="${1:-${FIREWALL:?Usage: ./build.sh [--test] [--dev] <hostname>}}"
if echo "$FIREWALL" | grep -q '@'; then
    REMOTE_USER=$(echo "$FIREWALL" | cut -d@ -f1)
else
    REMOTE_USER=$(ssh -G "$FIREWALL" 2>/dev/null | awk '/^user /{print $2}')
    REMOTE_USER="${REMOTE_USER:-$(whoami)}"
fi
REMOTE_REPO="/home/${REMOTE_USER}/src/banzai-plugins"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIST="${REPO_ROOT}/dist"

# ── helpers ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

remote() { ssh "${FIREWALL}" "$@"; }

# ── 0. Discover plugins ─────────────────────────────────────────────

echo "==> Building on ${FIREWALL}"

PLUGIN_DIRS=""
for dir in "${REPO_ROOT}"/*/; do
    for subdir in "${dir}"*/; do
        if [ -f "${subdir}Makefile" ] && grep -q 'PLUGIN_NAME' "${subdir}Makefile" 2>/dev/null; then
            rel="${subdir#${REPO_ROOT}/}"
            rel="${rel%/}"
            PLUGIN_DIRS="${PLUGIN_DIRS} ${rel}"
        fi
    done
done

[ -n "${PLUGIN_DIRS}" ] || die "No plugins found"
echo "    Plugins:${PLUGIN_DIRS}"

# ── 0b. Detect ABI and series from remote ────────────────────────────

echo "==> Detecting ABI and OPNsense series"

UNAME_INFO=$(remote "uname -sm")
OS_NAME=$(echo "${UNAME_INFO}" | awk '{print $1}')
OS_ARCH=$(echo "${UNAME_INFO}" | awk '{print $2}')
OS_MAJOR=$(remote "uname -r" | cut -d. -f1)
FREEBSD_ABI="${OS_NAME}:${OS_MAJOR}:${OS_ARCH}"
echo "    ABI: ${FREEBSD_ABI}"

SERIES=$(remote "opnsense-version -a")
[ -n "${SERIES}" ] || die "Failed to detect OPNsense series"
echo "    Series: ${SERIES}"

if [ "${DEV_MODE}" -eq 1 ]; then
    PAGES_REPO="${REPO_ROOT}/docs/${FREEBSD_ABI}/${SERIES}/dev/repo"
    echo "    Pages repo: docs/${FREEBSD_ABI}/${SERIES}/dev/repo/ (dev)"
else
    PAGES_REPO="${REPO_ROOT}/docs/${FREEBSD_ABI}/${SERIES}/repo"
    echo "    Pages repo: docs/${FREEBSD_ABI}/${SERIES}/repo/"
fi

# ── 1. Sync source to remote ────────────────────────────────────────

echo "==> Syncing to ${FIREWALL}"
remote "
    mkdir -p ${REMOTE_REPO}
    if [ ! -d ${REMOTE_REPO}/.git ]; then
        git -C ${REMOTE_REPO} init -q
        git -C ${REMOTE_REPO} commit --allow-empty -q -m init
    fi
"

# Sync build infrastructure from submodule
SUBMODULE_DIR="${REPO_ROOT}/opnsense-plugins"
[ -d "${SUBMODULE_DIR}/Mk" ] || die "Submodule not initialized. Run: make setup"

for infra_dir in Mk Keywords Templates Scripts; do
    echo "    Syncing ${infra_dir}/"
    rsync -aq --delete -e ssh "${SUBMODULE_DIR}/${infra_dir}/" "${FIREWALL}:${REMOTE_REPO}/${infra_dir}/"
done

if [ "${DEV_MODE}" -eq 1 ]; then
    # Create devel.mk to enable -devel package suffix and PLUGIN_TIER=4
    remote "echo 'PLUGIN_DEVEL?=yes' > ${REMOTE_REPO}/Mk/devel.mk"
    echo "    Dev mode: devel.mk active (packages will have -devel suffix)"
else
    # Override devel.mk to prevent -devel package suffix
    remote ": > ${REMOTE_REPO}/Mk/devel.mk"
fi

# Sync each plugin
for plugin_dir in ${PLUGIN_DIRS}; do
    REMOTE_PLUGIN_DIR="${REMOTE_REPO}/${plugin_dir}"
    LOCAL_PLUGIN_DIR="${REPO_ROOT}/${plugin_dir}"

    echo "    Syncing ${plugin_dir}/"
    rsync -aq --delete --exclude work/ -e ssh "${LOCAL_PLUGIN_DIR}/" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
done

# ── 2. Build each plugin ────────────────────────────────────────────

rm -rf "${LOCAL_DIST}"
mkdir -p "${LOCAL_DIST}"
BUILT_PKGS=""

for plugin_dir in ${PLUGIN_DIRS}; do
    REMOTE_PLUGIN_DIR="${REMOTE_REPO}/${plugin_dir}"

    echo ""
    echo "==> Building ${plugin_dir}"
    remote "sudo rm -rf ${REMOTE_PLUGIN_DIR}/work"
    remote "cd ${REMOTE_PLUGIN_DIR} && make package"

    PKG_PATH=$(remote "ls -1 ${REMOTE_PLUGIN_DIR}/work/pkg/*.pkg 2>/dev/null | head -1")
    [ -n "${PKG_PATH}" ] || die "No .pkg file found for ${plugin_dir}"
    PKG_NAME=$(basename "${PKG_PATH}")
    echo "    Built: ${PKG_NAME}"

    echo "    Downloading to ${LOCAL_DIST}/"
    rsync -aq -e ssh "${FIREWALL}:${PKG_PATH}" "${LOCAL_DIST}/"
    BUILT_PKGS="${BUILT_PKGS} ${PKG_NAME}"

    remote "sudo rm -rf ${REMOTE_PLUGIN_DIR}/work"
done

if [ "${TEST_MODE}" -eq 1 ]; then
    echo ""
    echo "==> Test mode: skipping repo signing and docs"
    echo ""
    echo "==> Done (test build)"
    echo "    Built packages:${BUILT_PKGS}"
    echo "    Packages in: dist/"
    exit 0
fi

BUILD_LABEL="stable"
if [ "${DEV_MODE}" -eq 1 ]; then
    BUILD_LABEL="dev"
fi

# ── 3. Update GitHub Pages repo ─────────────────────────────────────

echo ""
echo "==> Updating GitHub Pages pkg repo (${FREEBSD_ABI}/${SERIES}, ${BUILD_LABEL})"
mkdir -p "${PAGES_REPO}"

REMOTE_REPO_DIR="/tmp/banzai_plugins_repo"
remote "rm -rf ${REMOTE_REPO_DIR} && mkdir -p ${REMOTE_REPO_DIR}"

rsync -aq -e ssh "${LOCAL_DIST}/"*.pkg "${FIREWALL}:${REMOTE_REPO_DIR}/"

# Sign with YubiKey PIV via piv-sign-agent.py: the local agent's Unix socket
# is forwarded to the remote via SSH -R.
rsync -aq -e ssh \
    "${REPO_ROOT}/tools/sign-repo.py" \
    "${REPO_ROOT}/Keys/repo.pub" \
    "${FIREWALL}:${REMOTE_REPO_DIR}/"

# Ensure piv-sign-agent.py is running locally
LOCAL_PIV_SOCK="${PIV_AGENT_SOCK:-${HOME}/.piv-sign-agent/agent.sock}"
if [ ! -S "${LOCAL_PIV_SOCK}" ]; then
    die "PIV signing agent not running. Start it with: python3 tools/piv-sign-agent.py"
fi

REMOTE_PIV_SOCK="/tmp/piv-sign-agent.sock"
echo "    Signing repo (PIV key on this host via socket forwarding)..."

# Verify the local agent socket is live, not just a stale file.
if ! echo "PUBKEY" | nc -U "${LOCAL_PIV_SOCK}" 2>/dev/null | grep -q "^OK"; then
    die "PIV signing agent socket exists but is not responding. Restart with: python3 tools/piv-sign-agent.py"
fi

# Remove stale remote socket before forwarding.
# StreamLocalBindUnlink is not set on OPNsense sshd by default, so a stale
# socket file from a prior failed attempt blocks sshd from creating the
# new forwarding socket.
remote "rm -f ${REMOTE_PIV_SOCK}"

ssh -R "${REMOTE_PIV_SOCK}:${LOCAL_PIV_SOCK}" "${FIREWALL}" \
    "PIV_AGENT_SOCK=${REMOTE_PIV_SOCK} pkg repo ${REMOTE_REPO_DIR}/ signing_command: ${REMOTE_REPO_DIR}/sign-repo.py"

# pkg repo exits 0 even when signing fails — verify the signature was created
remote "test -f ${REMOTE_REPO_DIR}/meta.conf" || die "Repo signing failed (no meta.conf)"

remote "rm -f ${REMOTE_REPO_DIR}/sign-repo.py ${REMOTE_REPO_DIR}/repo.pub"
rsync -aq --delete -e ssh "${FIREWALL}:${REMOTE_REPO_DIR}/" "${PAGES_REPO}/"
remote "rm -rf ${REMOTE_REPO_DIR}"

# ── 4. Build documentation ───────────────────────────────────────────

echo ""
echo "==> Building documentation"
make -C "${REPO_ROOT}/docs/sphinx" html
echo "    Commit and push docs/ to update GitHub Pages."

echo ""
echo "==> Done (${BUILD_LABEL})"
echo "    Built packages:${BUILT_PKGS}"
echo "    Repo: ${PAGES_REPO#${REPO_ROOT}/}"
echo "    Docs: docs/releases/"
