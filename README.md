# PackageForge

**PackageForge** extends the KernelForge philosophy to userspace. It is an automated CI/CD pipeline designed to dynamically fetch, customize, rebuild, and publish any custom `.deb` or `.rpm` package using a single unified YAML manifest.

---

## 🚀 The Architecture

PackageForge operates through an 8-Phase pipeline executed entirely within GitHub Actions.

### 1. Package Manifest System (Phase 1)
Every package is defined by a declarative `package.yml` manifest stored in `packages/<pkgname>/package.yml`. This manifest acts as the absolute source of truth, dictating what upstream source to fetch, what the new identity will be, and how the files should be customized.
*No code modifications are needed to add a new package—simply drop in a new YAML folder!*

### 2. Fetch Layer (Phase 2)
The pipeline parses the manifest and fetches the upstream source. It intelligently uses Dockerized package managers (`apt` or `dnf`) to download `.deb` or `.rpm` packages directly, or falls back to `wget` and `git clone`. It caches the artifact and generates an `upstream.sha256` lockfile for reproducibility.

### 3. Unpack Layer (Phase 3)
A format-agnostic unpacking system. It detects whether the artifact is a `.deb` (extracts using `ar` and `tar`) or an `.rpm` (extracts using `rpm2cpio`), and normalizes both into a unified intermediate directory structure:
```text
unpacked/
  files/          # Actual package filesystem contents
  meta/
    control       # Normalized metadata (Name, Version, Arch, Desc)
    scripts/      # Pre/Post install scripts
```

### 4. Customization Layer (Phase 4)
*Bridging the gap.* The pipeline parses the `customize` block of the `package.yml` to apply string replacements, inject new configuration files, and execute build-time bash hooks against the normalized `unpacked/` layout.

### 5. Rebuild Layer (Phase 5)
Takes the normalized, customized layout and repacks it. It reuses the exact same Docker containers built by KernelForge (`kernel-builder-deb` and `kernel-builder-rpm`) to execute `dpkg-deb --build` or synthesize a `.spec` file on the fly for `rpmbuild`.

### 6. CI Workflow (Phase 6)
A fully automated GitHub Actions pipeline (`.github/workflows/ci.yml`). It uses a dynamic matrix strategy (`jq` scanning) to auto-discover all directories in `packages/` and process them in parallel across the `deb` and `rpm` formats.

### 7. Smoke Test (Phase 7)
Spins up a clean `debian:bookworm` or `fedora:latest` container to install the newly built artifact. It verifies package registration (`dpkg -l` / `rpm -q`), tests the main binary execution (`--version`), and runs `systemd-analyze verify` on any injected `.service` files.

### 8. Signing & Publishing (Phase 8)
Cryptographically signs the packages using imported GPG keys (`dpkg-sig` and `rpm --addsign`). It then builds a full APT repository (`reprepro`) and YUM repository (`createrepo_c`) and deploys the index files directly to the `gh-pages` branch, ready for users to consume via `/etc/apt/sources.list`.

---

## 🛠️ How to Add a New Package

1. Create a directory in `packages/`:
   ```bash
   mkdir -p packages/my-custom-app/files
   ```
2. Create `packages/my-custom-app/package.yml`:
   ```yaml
   source:
     type: apt
     name: htop
     version: "3.3.0"
     upstream_distro: ubuntu
   
   customize:
     package_name: "htop-acmecorp"
     vendor: "Acme Corp"
   ```
3. Commit and push. The CI pipeline will auto-detect the folder and build it!

---

## 🔒 Branch Protection Requirement

To maintain the integrity of the automated packaging pipeline, **branch protection rules** must be enforced on the `main` branch. 

Navigate to your repository's settings on GitHub:
1. Go to **Settings > Branches > Add branch protection rule**.
2. Set the Branch name pattern to `main`.
3. Check **Require status checks to pass before merging** and select the CI pipeline jobs.

---

## ⚠️ Potential Pipeline Failures

Building a universal package customization pipeline introduces several complex edge cases:

1. **Fetching**: Upstream package is renamed, removed, or auth rate-limits are hit. Checksum mismatches occur if upstream forces a hotfix without bumping the version tag.
2. **Unpacking**: Packages using complex `dpkg-divert` mechanisms or hardcoded paths in maintainer scripts.
3. **Customization**: Blind string replacements on binary executables will corrupt the files. Replacements must be strictly scoped to text/control files.
4. **Testing**: Renaming a package without correctly handling `Provides/Conflicts/Replaces` flags can break the dependency tree if both the original and custom package are installed simultaneously.
