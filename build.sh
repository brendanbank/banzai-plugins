#!/bin/sh
#
# Build all OPNsense plugin packages in banzai-plugins.
#
# Usage: ./build.sh [--test] <hostname>
#
# The build happens on a FreeBSD/OPNsense host via SSH. Build infrastructure
# comes from the opnsense-plugins/ submodule and is synced to the remote.
#
# After building, packages are downloaded to dist/ and the GitHub Pages pkg
# repo in docs/${ABI}/${SERIES}/repo/ is updated with signed packages.
# Signing uses a GPG signing subkey on a YubiKey via GPG agent forwarding
# (tools/sign-repo.sh runs on the remote, gpg-agent calls reach the local key).
#
# Options:
#   --test    Build only; skip repo signing, docs, and GitHub Pages update.
#

set -e

TEST_MODE=0
if [ "$1" = "--test" ]; then
    TEST_MODE=1
    shift
fi

FIREWALL="${1:-${FIREWALL:?Usage: ./build.sh [--test] <hostname>}}"
REMOTE_REPO="/home/brendan/src/banzai-plugins"
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

PAGES_REPO="${REPO_ROOT}/docs/${FREEBSD_ABI}/${SERIES}/repo"
echo "    Pages repo: docs/${FREEBSD_ABI}/${SERIES}/repo/"

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
    remote "rm -rf ${REMOTE_REPO}/${infra_dir}"
    scp -rq "${SUBMODULE_DIR}/${infra_dir}" "${FIREWALL}:${REMOTE_REPO}/"
done

# Override devel.mk to prevent -devel package suffix
remote ": > ${REMOTE_REPO}/Mk/devel.mk"

# Sync each plugin
for plugin_dir in ${PLUGIN_DIRS}; do
    REMOTE_PLUGIN_DIR="${REMOTE_REPO}/${plugin_dir}"
    LOCAL_PLUGIN_DIR="${REPO_ROOT}/${plugin_dir}"

    echo "    Syncing ${plugin_dir}/"
    remote "rm -rf ${REMOTE_PLUGIN_DIR}/src && mkdir -p ${REMOTE_PLUGIN_DIR}"
    scp -q "${LOCAL_PLUGIN_DIR}/Makefile" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    scp -q "${LOCAL_PLUGIN_DIR}/pkg-descr" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    scp -rq "${LOCAL_PLUGIN_DIR}/src" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    for hook in +POST_INSTALL.post +PRE_DEINSTALL.pre +PRE_INSTALL.pre +POST_DEINSTALL.post; do
        if [ -f "${LOCAL_PLUGIN_DIR}/${hook}" ]; then
            scp -q "${LOCAL_PLUGIN_DIR}/${hook}" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
        fi
    done
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
    scp -q "${FIREWALL}:${PKG_PATH}" "${LOCAL_DIST}/"
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

# ── 3. Update GitHub Pages repo ─────────────────────────────────────

echo ""
echo "==> Updating GitHub Pages pkg repo (${FREEBSD_ABI}/${SERIES})"
mkdir -p "${PAGES_REPO}"

REMOTE_REPO_DIR="/tmp/banzai_plugins_repo"
remote "rm -rf ${REMOTE_REPO_DIR} && mkdir -p ${REMOTE_REPO_DIR}"

for pkg in "${LOCAL_DIST}"/*.pkg; do
    [ -f "${pkg}" ] || continue
    scp -q "${pkg}" "${FIREWALL}:${REMOTE_REPO_DIR}/"
done

# Sign with YubiKey GPG key via agent forwarding: the remote gpg-agent
# socket is forwarded to the local agent (which has the YubiKey).
scp -q "${REPO_ROOT}/tools/sign-repo.sh" "${FIREWALL}:${REMOTE_REPO_DIR}/sign-repo.sh"
scp -q "${REPO_ROOT}/Keys/repo.pub" "${FIREWALL}:${REMOTE_REPO_DIR}/repo.pub"

echo "    Signing repo (GPG key on this host via agent forwarding)..."
REMOTE_GPG_SOCK=$(remote "gpgconf --list-dirs agent-socket")
LOCAL_GPG_EXTRA=$(gpgconf --list-dirs agent-extra-socket)

# Kill remote gpg-agent and remove stale socket before forwarding,
# otherwise ssh -R fails because the socket file already exists.
remote "gpgconf --kill gpg-agent; rm -f ${REMOTE_GPG_SOCK}"

ssh -R "${REMOTE_GPG_SOCK}:${LOCAL_GPG_EXTRA}" "${FIREWALL}" \
    "pkg repo ${REMOTE_REPO_DIR}/ signing_command: ${REMOTE_REPO_DIR}/sign-repo.sh"

# pkg repo exits 0 even when signing fails — verify the signature was created
remote "test -f ${REMOTE_REPO_DIR}/meta.conf" || die "Repo signing failed (no meta.conf)"

remote "rm -f ${REMOTE_REPO_DIR}/sign-repo.sh ${REMOTE_REPO_DIR}/repo.pub"
rm -f "${PAGES_REPO}"/*.pkg
rm -f "${PAGES_REPO}"/{meta.conf,packagesite.*,data.*,filesite.*}
scp -q "${FIREWALL}:${REMOTE_REPO_DIR}/*" "${PAGES_REPO}/"
remote "rm -rf ${REMOTE_REPO_DIR}"

# ── 4. Build documentation ───────────────────────────────────────────

echo ""
echo "==> Building documentation"
make -C "${REPO_ROOT}/docs/sphinx" html
echo "    Commit and push docs/ to update GitHub Pages."

echo ""
echo "==> Done"
echo "    Built packages:${BUILT_PKGS}"
echo "    Repo: docs/${FREEBSD_ABI}/${SERIES}/repo/"
echo "    Docs: docs/releases/"
