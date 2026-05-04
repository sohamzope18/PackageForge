#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# publish-repo.sh
# Phase 8: Package Signing & Publishing
#
# Assumes GPG key is already imported (e.g., via GitHub Actions).
# Signs .deb and .rpm packages, then generates APT and YUM repos.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

WORKSPACE="$(pwd)"
OUTPUT_DIR="${WORKSPACE}/output"
REPO_DIR="${WORKSPACE}/repo"

GPG_KEY_ID="${GPG_KEY_ID:-}"
if [[ -z "$GPG_KEY_ID" ]]; then
    echo "ERROR: GPG_KEY_ID environment variable is not set."
    exit 1
fi

echo "════════════════════════════════════════════"
echo " PackageForge Publishing Layer"
echo " Key ID: ${GPG_KEY_ID}"
echo "════════════════════════════════════════════"

# Install dependencies if missing (assuming Debian/Ubuntu runner)
if ! command -v dpkg-sig &> /dev/null || ! command -v reprepro &> /dev/null || ! command -v createrepo_c &> /dev/null; then
    echo "==> Installing dependencies (dpkg-sig, reprepro, createrepo-c, rpm)..."
    sudo apt-get update -qq
    sudo apt-get install -y dpkg-sig reprepro createrepo-c rpm
fi

# ── Configure RPM Signing ────────────────────────────────────
echo "==> Configuring RPM macros for signing..."
cat <<EOF > ~/.rpmmacros
%_signature gpg
%_gpg_name $GPG_KEY_ID
EOF

# ── Setup Repo Directories ───────────────────────────────────
mkdir -p "${REPO_DIR}/apt/conf"
mkdir -p "${REPO_DIR}/yum"

# ── 1. Sign and Process .deb Packages ────────────────────────
DEBS=( $(find "$OUTPUT_DIR" -name "*.deb" || true) )
if [[ ${#DEBS[@]} -gt 0 ]]; then
    echo "==> Signing ${#DEBS[@]} .deb packages..."
    for deb in "${DEBS[@]}"; do
        dpkg-sig -k "$GPG_KEY_ID" --sign builder "$deb"
    done
    
    echo "==> Generating APT Repository (reprepro)..."
    cat <<EOF > "${REPO_DIR}/apt/conf/distributions"
Codename: stable
Components: main
Architectures: amd64 arm64 source
SignWith: $GPG_KEY_ID
Description: PackageForge Custom APT Repository
EOF

    pushd "${REPO_DIR}/apt" > /dev/null
    for deb in "${DEBS[@]}"; do
        reprepro includedeb stable "$deb"
    done
    popd > /dev/null
else
    echo "No .deb packages found to sign."
fi

# ── 2. Sign and Process .rpm Packages ────────────────────────
RPMS=( $(find "$OUTPUT_DIR" -name "*.rpm" || true) )
if [[ ${#RPMS[@]} -gt 0 ]]; then
    echo "==> Signing ${#RPMS[@]} .rpm packages..."
    for rpm in "${RPMS[@]}"; do
        # We assume the key has no passphrase or passphrase is fed via agent
        rpm --addsign "$rpm"
        cp "$rpm" "${REPO_DIR}/yum/"
    done
    
    echo "==> Generating YUM Repository (createrepo_c)..."
    pushd "${REPO_DIR}/yum" > /dev/null
    createrepo_c .
    popd > /dev/null
else
    echo "No .rpm packages found to sign."
fi

echo "✅ Repositories generated successfully at: $REPO_DIR"
ls -la "$REPO_DIR"
