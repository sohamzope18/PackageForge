#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# rebuild-deb.sh
# Phase 5: Rebuild Layer (DEB)
#
# Reconstructs DEBIAN/control from meta/control and reassembles
# the unpacked files into a .deb using dpkg-deb inside Docker.
#
# Usage: bash scripts/rebuild-deb.sh <pkgname>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PKGNAME="${1:?Usage: rebuild-deb.sh <pkgname>}"
WORKSPACE="$(pwd)"
UNPACK_DIR="${WORKSPACE}/packages/${PKGNAME}/unpacked"
OUTPUT_DIR="${WORKSPACE}/output"

if [[ ! -d "$UNPACK_DIR" ]]; then
    echo "ERROR: Unpacked directory not found at $UNPACK_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "════════════════════════════════════════════"
echo " PackageForge Rebuild Layer (DEB)"
echo " Package: ${PKGNAME}"
echo "════════════════════════════════════════════"

# We use standard ubuntu image and install dpkg-dev dynamically
DOCKER_IMAGE="ubuntu:latest"

echo "==> Preparing build environment for dpkg-deb..."

# Create a temporary staging area that Docker will mount
STAGE_DIR="${WORKSPACE}/packages/${PKGNAME}/stage-deb"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# Copy all files
cp -a "${UNPACK_DIR}/files/"* "$STAGE_DIR/" 2>/dev/null || true

# Setup DEBIAN metadata directory
mkdir -p "${STAGE_DIR}/DEBIAN"

if [[ -f "${UNPACK_DIR}/meta/control" ]]; then
    cp "${UNPACK_DIR}/meta/control" "${STAGE_DIR}/DEBIAN/control"
else
    echo "ERROR: meta/control not found. Cannot build .deb."
    exit 1
fi

# Copy any maintainer scripts
if [[ -d "${UNPACK_DIR}/meta/scripts" ]]; then
    for script in preinst postinst prerm postrm; do
        if [[ -f "${UNPACK_DIR}/meta/scripts/$script" ]]; then
            cp "${UNPACK_DIR}/meta/scripts/$script" "${STAGE_DIR}/DEBIAN/$script"
            chmod 755 "${STAGE_DIR}/DEBIAN/$script"
        fi
    done
fi

echo "==> Running dpkg-deb --build inside Docker..."

# Run the build inside the container
docker run --rm \
    -v "$STAGE_DIR:/build" \
    -v "$OUTPUT_DIR:/output" \
    "$DOCKER_IMAGE" \
    bash -c "apt-get update -qq && apt-get install -y dpkg-dev >/dev/null && chown -R root:root /build && dpkg-deb --build /build /output/custom-${PKGNAME}.deb"

echo "✅ Rebuild complete: output/custom-${PKGNAME}.deb"
ls -la "$OUTPUT_DIR/custom-${PKGNAME}.deb"

# Cleanup staging
rm -rf "$STAGE_DIR"
