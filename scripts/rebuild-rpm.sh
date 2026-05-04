#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# rebuild-rpm.sh
# Phase 5: Rebuild Layer (RPM)
#
# Generates a basic binary .spec file from meta/control and
# reassembles the unpacked files into an .rpm using rpmbuild
# inside the KernelForge Docker container.
#
# Usage: bash scripts/rebuild-rpm.sh <pkgname>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PKGNAME="${1:?Usage: rebuild-rpm.sh <pkgname>}"
WORKSPACE="$(pwd)"
UNPACK_DIR="${WORKSPACE}/packages/${PKGNAME}/unpacked"
OUTPUT_DIR="${WORKSPACE}/output"

if [[ ! -d "$UNPACK_DIR" ]]; then
    echo "ERROR: Unpacked directory not found at $UNPACK_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "════════════════════════════════════════════"
echo " PackageForge Rebuild Layer (RPM)"
echo " Package: ${PKGNAME}"
echo "════════════════════════════════════════════"

DOCKER_IMAGE="kernel-builder-rpm:latest"

# ── Extract Metadata ─────────────────────────────────────────
CONTROL_FILE="${UNPACK_DIR}/meta/control"
if [[ ! -f "$CONTROL_FILE" ]]; then
    echo "ERROR: meta/control not found. Cannot generate .spec."
    exit 1
fi

get_meta() {
    grep -i "^$1:" "$CONTROL_FILE" | head -n 1 | sed -E "s/^$1:\s*//" || echo ""
}

META_NAME=$(get_meta "Package")
META_VERSION=$(get_meta "Version")
META_ARCH=$(get_meta "Architecture")
META_DESC=$(get_meta "Description")

# Default fallbacks
META_NAME="${META_NAME:-custom-$PKGNAME}"
META_VERSION="${META_VERSION:-1.0.0}"
META_ARCH="${META_ARCH:-x86_64}"
META_DESC="${META_DESC:-Custom repackaged binary via PackageForge.}"

# ── Setup Staging Area ───────────────────────────────────────
STAGE_DIR="${WORKSPACE}/packages/${PKGNAME}/stage-rpm"
rm -rf "$STAGE_DIR"
mkdir -p "${STAGE_DIR}/BUILD"
mkdir -p "${STAGE_DIR}/BUILDROOT"
mkdir -p "${STAGE_DIR}/RPMS"
mkdir -p "${STAGE_DIR}/SOURCES"
mkdir -p "${STAGE_DIR}/SPECS"
mkdir -p "${STAGE_DIR}/SRPMS"

# ── Generate Spec File ───────────────────────────────────────
SPEC_FILE="${STAGE_DIR}/SPECS/${META_NAME}.spec"

echo "==> Generating .spec file..."
cat <<EOF > "$SPEC_FILE"
Name:           ${META_NAME}
Version:        ${META_VERSION}
Release:        1%{?dist}
Summary:        ${META_DESC}
License:        Unknown
BuildArch:      ${META_ARCH}

# Disable debug package since this is a binary repack
%global debug_package %{nil}

%description
${META_DESC}

%prep
# No prep needed for binary repack

%build
# No build needed for binary repack

%install
# Copy everything from our mapped /unpacked/files to buildroot
mkdir -p %{buildroot}
cp -a /unpacked/files/* %{buildroot}/ 2>/dev/null || true

%files
# Include all files dynamically
/

%changelog
* $(date "+%a %b %d %Y") PackageForge CI - ${META_VERSION}-1
- Automated repackaging via PackageForge
EOF

# ── Run rpmbuild inside Docker ───────────────────────────────
echo "==> Running rpmbuild inside Docker..."

docker run --rm \
    -v "$STAGE_DIR:/root/rpmbuild" \
    -v "${UNPACK_DIR}:/unpacked:ro" \
    -v "$OUTPUT_DIR:/output" \
    "$DOCKER_IMAGE" \
    bash -c "rpmbuild -bb /root/rpmbuild/SPECS/${META_NAME}.spec && \
             find /root/rpmbuild/RPMS -name '*.rpm' -exec cp {} /output/ \;"

echo "✅ Rebuild complete: Check output/ directory for RPMs"
ls -la "$OUTPUT_DIR"/*.rpm 2>/dev/null || true

# Cleanup staging
rm -rf "$STAGE_DIR"
