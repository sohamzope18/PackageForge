#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# unpack-package.sh
# Phase 3: Unpack Layer for PackageForge
#
# Extracts fetched packages into a normalized layout:
# workspace/<pkgname>/unpacked/
#   files/          ← actual package contents
#   meta/
#     control       ← normalized key-value metadata
#     scripts/      ← preinst, postinst, prerm, postrm
#
# Usage: bash scripts/unpack-package.sh <pkgname>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PKGNAME="${1:?Usage: unpack-package.sh <pkgname>}"
WORKSPACE="$(pwd)"
MANIFEST="${WORKSPACE}/packages/${PKGNAME}/package.yml"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found at $MANIFEST"
    exit 1
fi

echo "════════════════════════════════════════════"
echo " PackageForge Unpack Layer"
echo " Package: ${PKGNAME}"
echo "════════════════════════════════════════════"

# ── Parse Manifest using Python ──────────────────────────────
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

SRC_VERSION=$(parse_yaml "source.version")
if [[ -z "$SRC_VERSION" ]]; then
    echo "ERROR: Could not parse source.version from manifest."
    exit 1
fi

CACHE_DIR="${WORKSPACE}/cache/${PKGNAME}/${SRC_VERSION}"
UNPACK_DIR="${WORKSPACE}/packages/${PKGNAME}/unpacked"

# ── Find Upstream Artifact ───────────────────────────────────
ARTIFACT=$(find "$CACHE_DIR" -type f -name "upstream.*" | head -n 1)

if [[ -z "$ARTIFACT" ]]; then
    echo "ERROR: No upstream artifact found in $CACHE_DIR. Did you run fetch-package.sh?"
    exit 1
fi

echo "Found artifact: $(basename "$ARTIFACT")"

# ── Setup Normalized Layout ──────────────────────────────────
rm -rf "$UNPACK_DIR"
mkdir -p "${UNPACK_DIR}/files"
mkdir -p "${UNPACK_DIR}/meta/scripts"

# ── Unpack Logic ─────────────────────────────────────────────
EXT="${ARTIFACT##*.}"

case "$EXT" in
    deb)
        echo "==> Unpacking Debian package (.deb)..."
        TMP_DEB="/tmp/pkgforge-deb-$$"
        mkdir -p "$TMP_DEB"
        
        # 1. Extract the ar archive
        pushd "$TMP_DEB" > /dev/null
        ar x "$ARTIFACT"
        
        # 2. Extract data to files/
        DATA_ARCHIVE=$(ls data.tar.* | head -n 1)
        if [[ -n "$DATA_ARCHIVE" ]]; then
            tar xf "$DATA_ARCHIVE" -C "${UNPACK_DIR}/files"
        fi
        
        # 3. Extract control metadata
        CONTROL_ARCHIVE=$(ls control.tar.* | head -n 1)
        if [[ -n "$CONTROL_ARCHIVE" ]]; then
            mkdir -p control_unpacked
            tar xf "$CONTROL_ARCHIVE" -C control_unpacked
            
            # Move standardized metadata
            if [[ -f "control_unpacked/control" ]]; then
                cp "control_unpacked/control" "${UNPACK_DIR}/meta/control"
            fi
            
            # Move maintainer scripts
            for script in preinst postinst prerm postrm; do
                if [[ -f "control_unpacked/$script" ]]; then
                    cp "control_unpacked/$script" "${UNPACK_DIR}/meta/scripts/$script"
                fi
            done
        fi
        popd > /dev/null
        rm -rf "$TMP_DEB"
        ;;
        
    rpm)
        echo "==> Unpacking RPM package (.rpm)..."
        # Extract files
        pushd "${UNPACK_DIR}/files" > /dev/null
        if command -v rpm2cpio &>/dev/null && command -v cpio &>/dev/null; then
            rpm2cpio "$ARTIFACT" | cpio -idmv --quiet
        else
            echo "ERROR: rpm2cpio or cpio not found. Cannot unpack .rpm."
            exit 1
        fi
        popd > /dev/null
        
        # Extract metadata into a normalized 'control' file format
        echo "Extracting RPM metadata..."
        if command -v rpm &>/dev/null; then
            rpm -qp --queryformat "Package: %{NAME}\nVersion: %{VERSION}\nArchitecture: %{ARCH}\nDescription: %{SUMMARY}\n" "$ARTIFACT" > "${UNPACK_DIR}/meta/control" 2>/dev/null || true
            
            # Extract maintainer scripts
            rpm -qp --scripts "$ARTIFACT" > "${UNPACK_DIR}/meta/rpm-scripts-raw.txt" 2>/dev/null || true
            
            # Note: Parsing the raw RPM scripts output into individual files (preinst, postinst)
            # is complex because rpm -qp --scripts dumps everything into one stream.
            # For this phase, we save the raw dump. A python parser could split it cleanly later.
            mv "${UNPACK_DIR}/meta/rpm-scripts-raw.txt" "${UNPACK_DIR}/meta/scripts/rpm_scripts.txt" 2>/dev/null || true
        else
            echo "WARNING: 'rpm' command not found. Cannot extract metadata."
            touch "${UNPACK_DIR}/meta/control"
        fi
        ;;
        
    gz|xz)
        # Assuming upstream.tar.gz or upstream.tar.xz
        echo "==> Unpacking Tarball archive..."
        tar xf "$ARTIFACT" -C "${UNPACK_DIR}/files"
        
        echo "Generating empty metadata for generic tarball..."
        cat <<EOF > "${UNPACK_DIR}/meta/control"
Package: ${PKGNAME}
Version: ${SRC_VERSION}
Description: Generic tarball source
EOF
        ;;
        
    *)
        echo "ERROR: Unsupported artifact format: $EXT"
        exit 1
        ;;
esac

echo "✅ Unpack complete."
echo "Layout generated at: $UNPACK_DIR"
ls -la "$UNPACK_DIR"
