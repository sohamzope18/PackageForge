#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# fetch-package.sh
# Phase 2: Fetch Layer for PackageForge
#
# Usage: bash scripts/fetch-package.sh <pkgname>
# Example: bash scripts/fetch-package.sh htop
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PKGNAME="${1:?Usage: fetch-package.sh <pkgname>}"
WORKSPACE="$(pwd)"
MANIFEST="${WORKSPACE}/packages/${PKGNAME}/package.yml"
CACHE_BASE="${WORKSPACE}/cache/${PKGNAME}"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Manifest not found at $MANIFEST"
    exit 1
fi

echo "════════════════════════════════════════════"
echo " PackageForge Fetch Layer"
echo " Package: ${PKGNAME}"
echo "════════════════════════════════════════════"

# ── Parse Manifest using Python ──────────────────────────────
# We use Python with PyYAML since yq might not be available
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

SRC_TYPE=$(parse_yaml "source.type")
SRC_NAME=$(parse_yaml "source.name")
SRC_VERSION=$(parse_yaml "source.version")
UPSTREAM_DISTRO=$(parse_yaml "source.upstream_distro")

if [[ -z "$SRC_TYPE" || -z "$SRC_NAME" || -z "$SRC_VERSION" ]]; then
    echo "ERROR: Missing required source fields (type, name, version) in manifest."
    exit 1
fi

echo "Source Type:     ${SRC_TYPE}"
echo "Source Name:     ${SRC_NAME}"
echo "Source Version:  ${SRC_VERSION}"

CACHE_DIR="${CACHE_BASE}/${SRC_VERSION}"
mkdir -p "$CACHE_DIR"

LOCKFILE="${WORKSPACE}/packages/${PKGNAME}/upstream.sha256"

# ── Check Lockfile ───────────────────────────────────────────
if [[ -f "$LOCKFILE" ]]; then
    echo "Lockfile found: $LOCKFILE"
    CACHED_FILE=$(find "$CACHE_DIR" -type f -name "upstream.*" | head -n 1)
    if [[ -n "$CACHED_FILE" ]]; then
        echo "Verifying cached file against lockfile..."
        pushd "$CACHE_DIR" > /dev/null
        if sha256sum -c "$LOCKFILE" --status; then
            echo "✅ Cached file is valid. Skipping fetch."
            popd > /dev/null
            exit 0
        else
            echo "⚠️  Checksum mismatch! Cached file is invalid or outdated."
            rm -f "$CACHED_FILE"
        fi
        popd > /dev/null
    else
        echo "No cached file found. Will fetch."
    fi
else
    echo "No lockfile found. Will generate one after fetch."
fi

# ── Fetch Logic ──────────────────────────────────────────────
echo ""
echo "==> Fetching upstream source..."

case "$SRC_TYPE" in
    apt)
        DISTRO=${UPSTREAM_DISTRO:-ubuntu}
        echo "Using Docker ($DISTRO) to fetch apt package..."
        docker run --rm \
            -v "$CACHE_DIR:/output" \
            "${DISTRO}:latest" \
            bash -c "apt-get update -qq && \
                     cd /output && \
                     apt-get download ${SRC_NAME}=${SRC_VERSION}* || \
                     apt-get download ${SRC_NAME}"
                     
        # Rename the downloaded file to a predictable name
        DEB_FILE=$(ls "$CACHE_DIR"/*.deb | head -n 1)
        if [[ -n "$DEB_FILE" ]]; then
            mv "$DEB_FILE" "${CACHE_DIR}/upstream.deb"
        fi
        ;;
        
    rpm-repo)
        DISTRO=${UPSTREAM_DISTRO:-fedora}
        echo "Using Docker ($DISTRO) to fetch rpm source package..."
        docker run --rm \
            -v "$CACHE_DIR:/output" \
            "${DISTRO}:latest" \
            bash -c "dnf install -y dnf-plugins-core && \
                     cd /output && \
                     dnf download --source ${SRC_NAME}-${SRC_VERSION}"
                     
        # Rename the downloaded file to a predictable name
        RPM_FILE=$(ls "$CACHE_DIR"/*.rpm | head -n 1)
        if [[ -n "$RPM_FILE" ]]; then
            mv "$RPM_FILE" "${CACHE_DIR}/upstream.rpm"
        fi
        ;;
        
    url)
        SRC_URL=$(parse_yaml "source.url")
        if [[ -z "$SRC_URL" ]]; then
            echo "ERROR: URL source requires source.url in manifest."
            exit 1
        fi
        echo "Downloading from URL: $SRC_URL"
        wget -q --show-progress -O "${CACHE_DIR}/upstream.tar.gz" "$SRC_URL"
        ;;
        
    git)
        SRC_URL=$(parse_yaml "source.url")
        if [[ -z "$SRC_URL" ]]; then
            echo "ERROR: Git source requires source.url in manifest."
            exit 1
        fi
        echo "Cloning from Git: $SRC_URL (Tag: $SRC_VERSION)"
        TMP_CLONE="/tmp/pkg-clone-$$"
        git clone --depth 1 --branch "$SRC_VERSION" "$SRC_URL" "$TMP_CLONE"
        # Create a deterministic tarball
        tar -czf "${CACHE_DIR}/upstream.tar.gz" -C "$TMP_CLONE" .
        rm -rf "$TMP_CLONE"
        ;;
        
    *)
        echo "ERROR: Unknown source type: $SRC_TYPE"
        exit 1
        ;;
esac

# ── Validate and generate lockfile ───────────────────────────
FETCHED_FILE=$(find "$CACHE_DIR" -type f -name "upstream.*" | head -n 1)

if [[ -z "$FETCHED_FILE" ]]; then
    echo "ERROR: Failed to fetch upstream artifact."
    exit 1
fi

echo ""
echo "==> Generating SHA256 lockfile..."
pushd "$CACHE_DIR" > /dev/null
FILENAME=$(basename "$FETCHED_FILE")
sha256sum "$FILENAME" > "$LOCKFILE"
popd > /dev/null

echo "✅ Fetch complete: $FETCHED_FILE"
echo "✅ Lockfile updated: $LOCKFILE"
