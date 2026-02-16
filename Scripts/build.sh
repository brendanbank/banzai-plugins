#!/bin/sh
#
# Build all OPNsense plugin packages in banzai-plugins.
#
# Usage: ./Scripts/build.sh <hostname>
#
# The build happens on a FreeBSD/OPNsense host via SSH. Build infrastructure
# (Mk/, Keywords/, etc.) is included in the repo and synced to the remote.
#
# After building, packages are downloaded to dist/ and the GitHub Pages pkg
# repo in docs/repo/ is updated. Plugins are NOT installed on the firewall;
# they are installed via the OPNsense UI (System > Firmware > Plugins).
#

set -e

FIREWALL="${1:-${FIREWALL:?Usage: ./Scripts/build.sh <hostname>}}"
REMOTE_REPO="/home/brendan/src/banzai-plugins"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_DIST="${REPO_ROOT}/dist"
PAGES_REPO="${REPO_ROOT}/docs/repo"
OP_ITEM="banzai-plugins pkg repo signing key"

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

# ── 1. Sync source to remote ────────────────────────────────────────

echo "==> Syncing to ${FIREWALL}"
remote "
    mkdir -p ${REMOTE_REPO}
    if [ ! -d ${REMOTE_REPO}/.git ]; then
        git -C ${REMOTE_REPO} init -q
        git -C ${REMOTE_REPO} commit --allow-empty -q -m init
    fi
"

# Sync build infrastructure
for infra_dir in Mk Keywords Templates Scripts; do
    echo "    Syncing ${infra_dir}/"
    remote "rm -rf ${REMOTE_REPO}/${infra_dir}"
    scp -rq "${REPO_ROOT}/${infra_dir}" "${FIREWALL}:${REMOTE_REPO}/"
done

# Sync each plugin
for plugin_dir in ${PLUGIN_DIRS}; do
    REMOTE_PLUGIN_DIR="${REMOTE_REPO}/${plugin_dir}"
    LOCAL_PLUGIN_DIR="${REPO_ROOT}/${plugin_dir}"

    echo "    Syncing ${plugin_dir}/"
    remote "rm -rf ${REMOTE_PLUGIN_DIR}/src && mkdir -p ${REMOTE_PLUGIN_DIR}"
    scp -q "${LOCAL_PLUGIN_DIR}/Makefile" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    scp -q "${LOCAL_PLUGIN_DIR}/pkg-descr" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    scp -rq "${LOCAL_PLUGIN_DIR}/src" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
    for hook in +POST_INSTALL.post +PRE_DEINSTALL.pre +PRE_INSTALL.pre; do
        if [ -f "${LOCAL_PLUGIN_DIR}/${hook}" ]; then
            scp -q "${LOCAL_PLUGIN_DIR}/${hook}" "${FIREWALL}:${REMOTE_PLUGIN_DIR}/"
        fi
    done
done

# ── 2. Build each plugin ────────────────────────────────────────────

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

# ── 3. Update GitHub Pages repo ─────────────────────────────────────

if [ -d "${PAGES_REPO}" ]; then
    echo ""
    echo "==> Updating GitHub Pages pkg repo"
    REMOTE_REPO_DIR="/tmp/banzai_plugins_repo"
    remote "rm -rf ${REMOTE_REPO_DIR} && mkdir -p ${REMOTE_REPO_DIR}"

    for pkg in "${LOCAL_DIST}"/*.pkg; do
        [ -f "${pkg}" ] || continue
        scp -q "${pkg}" "${FIREWALL}:${REMOTE_REPO_DIR}/"
    done

    # Fetch signing key from 1Password and convert PKCS#8 to PKCS#1 for pkg(8)
    echo "    Fetching signing key from 1Password..."
    SIGNING_KEY=$(mktemp)
    SIGNING_KEY_RSA=$(mktemp)
    trap 'rm -f "${SIGNING_KEY}" "${SIGNING_KEY_RSA}"' EXIT
    op item get "${OP_ITEM}" --fields notesPlain --format json \
        | jq -r '.value' > "${SIGNING_KEY}" \
        || die "Failed to fetch signing key from 1Password"
    openssl rsa -in "${SIGNING_KEY}" -out "${SIGNING_KEY_RSA}" -traditional 2>/dev/null \
        || die "Failed to convert signing key to PKCS#1 format"
    scp -q "${SIGNING_KEY_RSA}" "${FIREWALL}:${REMOTE_REPO_DIR}/repo.key"
    rm -f "${SIGNING_KEY}" "${SIGNING_KEY_RSA}"

    echo "    Signing repo..."
    remote "pkg repo ${REMOTE_REPO_DIR}/ rsa:${REMOTE_REPO_DIR}/repo.key"
    remote "rm -f ${REMOTE_REPO_DIR}/repo.key"

    rm -f "${PAGES_REPO}"/*.pkg
    rm -f "${PAGES_REPO}"/{meta.conf,packagesite.*,data.*,filesite.*}
    scp -q "${FIREWALL}:${REMOTE_REPO_DIR}/*" "${PAGES_REPO}/"
    remote "rm -rf ${REMOTE_REPO_DIR}"
    echo "    Commit and push docs/ to update GitHub Pages."
fi

echo ""
echo "==> Done"
echo "    Built packages:${BUILT_PKGS}"
