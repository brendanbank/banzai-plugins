#!/bin/sh
#
# Generate a core patch for a given OPNsense release tag.
#
# Usage: ./scripts/generate-patch.sh <release-tag> [core-repo-path]
#
# Examples:
#   ./scripts/generate-patch.sh 26.1.2
#   ./scripts/generate-patch.sh 26.1.2 /path/to/core
#
# The script extracts the three core Kea files from the specified tag in the
# opnsense/core repository, applies the DDNS hook code, and generates a
# unified diff saved as patches/<series>.patch.

set -e

TAG="${1:?Usage: ./scripts/generate-patch.sh <release-tag> [core-repo-path]}"
CORE_REPO="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Derive series from tag: 26.1.2 -> 26.1
SERIES=$(echo "$TAG" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')

PATCH_DIR="$REPO_ROOT/src/opnsense/data/kea-ddns/patches"
PATCH_FILE="$PATCH_DIR/$SERIES.patch"

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Locate core repo ────────────────────────────────────────────────

if [ -z "$CORE_REPO" ]; then
    # Try common locations relative to this repo
    for candidate in "$REPO_ROOT/../core" "$REPO_ROOT/../opnsense-core" \
                     "$REPO_ROOT/../../core" "$REPO_ROOT/../../opnsense-core" \
                     "$REPO_ROOT/../../../core" "$REPO_ROOT/../../../opnsense-core"; do
        if [ -e "$candidate/.git" ]; then
            CORE_REPO="$candidate"
            break
        fi
    done
    [ -n "$CORE_REPO" ] || die "Cannot find opnsense/core repo. Pass path as second argument."
fi

CORE_REPO="$(cd "$CORE_REPO" 2>/dev/null && pwd)" || die "Core repo not found at $2"
[ -e "$CORE_REPO/.git" ] || die "$CORE_REPO is not a git repository"

echo "==> Generating patch for OPNsense $TAG (series $SERIES)"
echo "    Core repo: $CORE_REPO"

# ── Fetch tags ───────────────────────────────────────────────────────

echo "==> Fetching tags"
cd "$CORE_REPO"
git fetch upstream --tags 2>/dev/null || git fetch origin --tags 2>/dev/null || true
git rev-parse "$TAG" >/dev/null 2>&1 || die "Tag '$TAG' not found in $CORE_REPO"

# ── Set up work directory ────────────────────────────────────────────

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/a/etc/inc/plugins.inc.d"
mkdir -p "$WORK/a/opnsense/mvc/app/models/OPNsense/Kea"
mkdir -p "$WORK/b/etc/inc/plugins.inc.d"
mkdir -p "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea"

# ── Extract files from the tag ───────────────────────────────────────

echo "==> Extracting core files from tag $TAG"

git show "$TAG:src/etc/inc/plugins.inc.d/kea.inc" \
    > "$WORK/a/etc/inc/plugins.inc.d/kea.inc" 2>/dev/null \
    || die "kea.inc not found at tag $TAG"

git show "$TAG:src/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php" \
    > "$WORK/a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php" 2>/dev/null \
    || die "KeaDhcpv4.php not found at tag $TAG"

git show "$TAG:src/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php" \
    > "$WORK/a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php" 2>/dev/null \
    || die "KeaDhcpv6.php not found at tag $TAG"

cp "$WORK/a/etc/inc/plugins.inc.d/kea.inc" "$WORK/b/etc/inc/plugins.inc.d/"
cp "$WORK/a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php" "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/"
cp "$WORK/a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php" "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/"

# ── Apply hooks to b/ copies ────────────────────────────────────────

echo "==> Applying DDNS hooks"

# --- kea.inc: Hook 1 — DDNS config generation + keactrl toggle ---
# Insert after: (new \OPNsense\Kea\KeaCtrlAgent())->generateConfig();

cat > "$WORK/hook_generate.php" << 'HOOK'
        /* let plugins generate supplementary configs (e.g. kea-dhcp-ddns.conf) */
        $ddnsResults = plugins_run('kea_ddns_generate');
        $ddnsEnabled = !empty($ddnsResults);
        /* enable/disable DDNS daemon in keactrl.conf */
        $keactrl = '/usr/local/etc/kea/keactrl.conf';
        $keactrlContent = @file_get_contents($keactrl);
        if ($keactrlContent !== false) {
            $keactrlContent = preg_replace(
                '/^dhcp_ddns=.*$/m',
                'dhcp_ddns=' . ($ddnsEnabled ? 'yes' : 'no'),
                $keactrlContent
            );
            @file_put_contents($keactrl, $keactrlContent);
        }
HOOK

HOOKFILE="$WORK/hook_generate.php" awk '
    { print }
    index($0, "KeaCtrlAgent") && index($0, "generateConfig") {
        while ((getline line < ENVIRON["HOOKFILE"]) > 0) print line
        close(ENVIRON["HOOKFILE"])
    }
' "$WORK/b/etc/inc/plugins.inc.d/kea.inc" > "$WORK/kea.inc.tmp"
mv "$WORK/kea.inc.tmp" "$WORK/b/etc/inc/plugins.inc.d/kea.inc"

# --- kea.inc: Hook 2 — add kea-dhcp-ddns to syslog facilities ---

sed "s/'kea-ctrl-agent'\]/'kea-ctrl-agent', 'kea-dhcp-ddns'\]/" \
    "$WORK/b/etc/inc/plugins.inc.d/kea.inc" > "$WORK/kea.inc.tmp"
mv "$WORK/kea.inc.tmp" "$WORK/b/etc/inc/plugins.inc.d/kea.inc"

# --- KeaDhcpv4.php: overlay hook ---
# Insert before: File::file_put_contents($target, json_encode($cnf, ...

cat > "$WORK/hook_v4.php" << 'HOOK'
        /* allow plugins to overlay config (e.g. DDNS parameters) */
        foreach (plugins_run('kea_dhcpv4_config') as $overlay) {
            if (isset($overlay['global'])) {
                $cnf['Dhcp4'] = array_merge($cnf['Dhcp4'], $overlay['global']);
            }
            if (isset($overlay['subnets'])) {
                foreach ($cnf['Dhcp4']['subnet4'] as &$subnet) {
                    if (isset($overlay['subnets'][$subnet['subnet']])) {
                        $subnet = array_merge($subnet, $overlay['subnets'][$subnet['subnet']]);
                    }
                }
                unset($subnet);
            }
        }
HOOK

HOOKFILE="$WORK/hook_v4.php" awk '
    index($0, "File::file_put_contents") && index($0, "json_encode") {
        while ((getline line < ENVIRON["HOOKFILE"]) > 0) print line
        close(ENVIRON["HOOKFILE"])
    }
    { print }
' "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php" > "$WORK/KeaDhcpv4.tmp"
mv "$WORK/KeaDhcpv4.tmp" "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php"

# --- KeaDhcpv6.php: overlay hook ---

cat > "$WORK/hook_v6.php" << 'HOOK'
        /* allow plugins to overlay config (e.g. DDNS parameters) */
        foreach (plugins_run('kea_dhcpv6_config') as $overlay) {
            if (isset($overlay['global'])) {
                $cnf['Dhcp6'] = array_merge($cnf['Dhcp6'], $overlay['global']);
            }
            if (isset($overlay['subnets'])) {
                foreach ($cnf['Dhcp6']['subnet6'] as &$subnet) {
                    if (isset($overlay['subnets'][$subnet['subnet']])) {
                        $subnet = array_merge($subnet, $overlay['subnets'][$subnet['subnet']]);
                    }
                }
                unset($subnet);
            }
        }
HOOK

HOOKFILE="$WORK/hook_v6.php" awk '
    index($0, "File::file_put_contents") && index($0, "json_encode") {
        while ((getline line < ENVIRON["HOOKFILE"]) > 0) print line
        close(ENVIRON["HOOKFILE"])
    }
    { print }
' "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php" > "$WORK/KeaDhcpv6.tmp"
mv "$WORK/KeaDhcpv6.tmp" "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php"

# ── Verify hooks were applied ────────────────────────────────────────

echo "==> Verifying hooks"

grep -q 'kea_ddns_generate' "$WORK/b/etc/inc/plugins.inc.d/kea.inc" \
    || die "Hook kea_ddns_generate not found in kea.inc"
grep -q 'kea-dhcp-ddns' "$WORK/b/etc/inc/plugins.inc.d/kea.inc" \
    || die "Syslog facility kea-dhcp-ddns not found in kea.inc"
grep -q 'kea_dhcpv4_config' "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php" \
    || die "Hook kea_dhcpv4_config not found in KeaDhcpv4.php"
grep -q 'kea_dhcpv6_config' "$WORK/b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php" \
    || die "Hook kea_dhcpv6_config not found in KeaDhcpv6.php"

# ── Generate the unified diff ────────────────────────────────────────

echo "==> Generating patch"

cd "$WORK"
{
    git diff --no-index --no-prefix --patience -- \
        a/etc/inc/plugins.inc.d/kea.inc \
        b/etc/inc/plugins.inc.d/kea.inc || true
    git diff --no-index --no-prefix --patience -- \
        a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php \
        b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php || true
    git diff --no-index --no-prefix --patience -- \
        a/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php \
        b/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php || true
} | sed '/^diff --git/d; /^index /d; s/^ $//' > "$PATCH_FILE"

[ -s "$PATCH_FILE" ] || die "Generated patch is empty — hooks may already be present at tag $TAG"

# ── Verify round-trip ────────────────────────────────────────────────

echo "==> Verifying forward apply"
cd "$WORK"
cp -r a verify-fwd
cd verify-fwd
patch --forward --strip=1 < "$PATCH_FILE" > /dev/null \
    || die "Generated patch does not apply cleanly (forward)"

echo "==> Verifying reverse apply"
patch --reverse --strip=1 < "$PATCH_FILE" > /dev/null \
    || die "Generated patch does not reverse cleanly"

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "==> Patch saved to: $PATCH_FILE"
echo "    Series: $SERIES"
echo "    Tag:    $TAG"
