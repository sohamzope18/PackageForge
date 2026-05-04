#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# smoke-test.sh
# Phase 7: Smoke Test Layer
#
# Tests the freshly built .deb or .rpm package in a clean container.
#
# Usage: bash scripts/smoke-test.sh <pkgname> <format>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PKGNAME="${1:?Usage: smoke-test.sh <pkgname> <format>}"
FORMAT="${2:?Usage: smoke-test.sh <pkgname> <format>}"
WORKSPACE="$(pwd)"
MANIFEST="${WORKSPACE}/packages/${PKGNAME}/package.yml"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found at $MANIFEST"
    exit 1
fi

echo "════════════════════════════════════════════"
echo " PackageForge Smoke Test"
echo " Package: ${PKGNAME}"
echo " Format:  ${FORMAT}"
echo "════════════════════════════════════════════"

parse_yaml() {
    python3 -c "
import sys, yaml
try:
    with open('$MANIFEST', 'r') as f:
        data = yaml.safe_load(f)
        keys = sys.argv[1].split('.')
        for k in keys:
            data = data[k]
        print(data)
except Exception as e:
    sys.exit(1)
" "$1" || echo ""
}

# The customized package name (e.g. htop-acmecorp)
CUSTOM_NAME=$(parse_yaml "customize.package_name")
if [[ -z "$CUSTOM_NAME" ]]; then
    CUSTOM_NAME="$PKGNAME"
fi

# The original package name, often matches the binary name (e.g. htop)
ORIG_NAME=$(parse_yaml "source.name")
if [[ -z "$ORIG_NAME" ]]; then
    ORIG_NAME="$PKGNAME"
fi

OUTPUT_DIR="${WORKSPACE}/output"

# ── Test Logic ──────────────────────────────────────────────
run_test() {
    local container_img="$1"
    local install_cmd="$2"
    local verify_cmd="$3"
    
    echo "==> Running tests in ${container_img}..."
    docker run --rm -v "$OUTPUT_DIR:/output:ro" "$container_img" bash -c "
        set -euo pipefail
        
        echo '[1/4] Installing package...'
        $install_cmd /output/custom-${PKGNAME}.${FORMAT} > /dev/null
        
        echo '[2/4] Verifying package registration...'
        $verify_cmd $CUSTOM_NAME > /dev/null || { echo 'ERROR: Package not registered correctly!'; exit 1; }
        
        echo '[3/4] Verifying binary execution...'
        if command -v $ORIG_NAME > /dev/null; then
            $ORIG_NAME --version || $ORIG_NAME --help || { echo 'ERROR: Binary execution failed!'; exit 1; }
        elif command -v $CUSTOM_NAME > /dev/null; then
            $CUSTOM_NAME --version || $CUSTOM_NAME --help || { echo 'ERROR: Binary execution failed!'; exit 1; }
        else
            echo 'WARNING: Could not find binary matching $ORIG_NAME or $CUSTOM_NAME. Skipping execution test.'
        fi
        
        echo '[4/4] Verifying systemd units (if any)...'
        if command -v systemd-analyze > /dev/null; then
            for svc in /lib/systemd/system/${ORIG_NAME}*.service /usr/lib/systemd/system/${ORIG_NAME}*.service; do
                if [[ -f \"\$svc\" ]]; then
                    echo \"Testing systemd service: \$svc\"
                    systemd-analyze verify \"\$svc\" || { echo 'ERROR: systemd verification failed!'; exit 1; }
                fi
            done
        fi
        
        echo '✅ All smoke tests passed inside container!'
    "
}

case "$FORMAT" in
    deb)
        run_test "debian:bookworm" "apt-get update -qq && apt-get install -y" "dpkg -l"
        ;;
    rpm)
        run_test "fedora:latest" "dnf install -y" "rpm -q"
        ;;
    *)
        echo "ERROR: Unsupported format for smoke test: $FORMAT"
        exit 1
        ;;
esac
