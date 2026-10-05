# Reproducible Builds and Supply Chain Security

Tako enforces deterministic, bit-for-bit reproducible compilation for its core engine artifact (`libtako_core.a`) and publishes machine-readable Software Bill of Materials (SBOM) metadata alongside every release.

This document records the pinned build inputs, environment variables, reproduction steps, and verification procedures required to independently audit and reproduce release builds.

---

## 1. Pinned Build Inputs

A reproducible build requires that all compiler, dependency, and toolchain versions are strictly pinned and cryptographically verifiable.

### 1.1 Compiler Toolchain

The Rust toolchain is pinned via [`rust-toolchain.toml`](../rust-toolchain.toml) in the repository root:

```toml
[toolchain]
channel = "1.97.1"
components = ["rustfmt", "clippy"]
targets = ["aarch64-apple-darwin", "aarch64-apple-ios", "aarch64-apple-ios-sim"]
profile = "minimal"
```

When building inside the repository, `rustup` automatically selects and enforces this exact compiler version (`rustc 1.97.1 (8bab26f4f 2026-07-14)`).

### 1.2 Dependency Lockfiles

- **Rust dependencies**: Fully locked in [`Cargo.lock`](../Cargo.lock). Every third-party dependency is pinned to an exact version and associated with its SHA-256 crate checksum from crates.io.
- **Swift binary dependencies**: Cryptographically pinned via SHA-256 checksums in [`Package.swift`](../Package.swift).

### 1.3 SDK and Target Architecture

- **Host architecture**: Apple silicon (`aarch64-apple-darwin`).
- **macOS deployment target**: `MACOSX_DEPLOYMENT_TARGET=14.0`.
- **iOS deployment target**: `IPHONEOS_DEPLOYMENT_TARGET=17.0`.

---

## 2. Environmental Determinism Controls

Modern compilers embed timestamps, host paths, and build directory hierarchies into binaries unless controlled. The following environment flags normalize the build environment:

| Variable | Value | Purpose |
|---|---|---|
| `SOURCE_DATE_EPOCH` | Unix timestamp (e.g. `$(git log -1 --pretty=%ct)`) | Replaces dynamic compilation timestamps in build outputs. |
| `ZERO_AR_DATE` | `1` | Forces Darwin `ar`, `ranlib`, and `libtool` to write zeroed timestamps in static archive headers (`.a`). |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | Normalizes Mach-O min-OS version headers. |
| `RUSTFLAGS` | `--remap-path-prefix=<build_dir>=/tako` | Remaps absolute filesystem paths to `/tako` across debug symbols, panic strings, and symbols. |

---

## 3. Step-by-Step Reproduction Instructions

To reproduce the engine artifact `libtako_core.a` on any Mac:

### Step 1: Clone the repository at the release tag

```bash
git clone https://github.com/alex09x/tako.git
cd tako
git checkout v<version>
```

### Step 2: Set deterministic environment variables

```bash
# Set epoch to the release commit's author timestamp
export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export ZERO_AR_DATE=1
export MACOSX_DEPLOYMENT_TARGET=14.0
export RUSTFLAGS="--remap-path-prefix=$(pwd)=/tako"
```

### Step 3: Compile the release static library

```bash
cargo build --release --lib --features ssh --target aarch64-apple-darwin
```

### Step 4: Verify the checksum

Calculate the SHA-256 checksum of the compiled static library:

```bash
shasum -a 256 target/aarch64-apple-darwin/release/libtako_core.a
```

The resulting hash will be identical regardless of the directory in which the repository was cloned or built.

---

## 4. Automated Verification Script

The repository includes an automated verification script that compiles the engine across two completely independent, isolated temporary directories with separate path roots and verifies that the output checksums match bit-for-bit:

```bash
./scripts/verify-reproducible-build.sh
```

Example output:

```text
🔬 Starting reproducible build verification across isolated build trees...
   Rustc:               rustc 1.97.1 (8bab26f4f 2026-07-14)
   Cargo:               cargo 1.97.1 (8bab26f4f 2026-07-14)
   SOURCE_DATE_EPOCH:   1700000000
   ZERO_AR_DATE:        1
   DEPLOYMENT_TARGET:   14.0
📂 Staging Build A...
📂 Staging Build B...
🔨 [1/2] Compiling Build A (path prefix: ... -> /tako)...
🔨 [2/2] Compiling Build B (path prefix: ... -> /tako)...
📊 Comparing build artifacts:
   Build A SHA256: 6fa731d7e2978d1...
   Build B SHA256: 6fa731d7e2978d1...
✅ SUCCESS: Bit-for-bit reproducible engine artifact confirmed!
   Both independent builds produced byte-identical libtako_core.a.
```

---

## 5. Software Bill of Materials (SBOM)

Every release ships with complete SBOM metadata in two standard formats:
1. **SPDX 2.3 JSON**: [`Tako-<version>-sbom.spdx.json`](https://spdx.dev/)
2. **CycloneDX 1.5 JSON**: [`Tako-<version>-sbom.cdx.json`](https://cyclonedx.org/)

### 5.1 SBOM Generation

SBOM files are generated from `Cargo.lock` and `Package.swift` via [`scripts/generate-sbom.py`](../scripts/generate-sbom.py):

```bash
python3 scripts/generate-sbom.py --version <version> --output-dir target/macapp
```

The SBOM documents:
- Root application details (version, repository, license `MIT`, author `Alexander Panasenko`).
- All 15+ direct and transitive Rust dependencies with Package URL (`pkg:cargo/<name>@<version>`), download URLs, and SHA-256 crate hashes.
- Swift package dependencies and binary targets with SHA-256 checksums.
- `DEPENDS_ON` and `DESCRIBES` dependency relationship graphs.

### 5.2 Release Distribution

Release SBOMs are packaged into release archives and attached directly to each [GitHub Release](https://github.com/alex09x/tako/releases) alongside `Tako-<version>.dmg` and `Tako-<version>.zip`.
