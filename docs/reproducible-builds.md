# Reproducible Builds and Supply Chain Security

Tako builds against released, checksummed inputs rather than compiling its
engine or its session runtime itself, and publishes machine-readable Software
Bill of Materials (SBOM) metadata alongside every release.

---

## 1. Pinned Build Inputs

### 1.1 The engine and its terminal views

The terminal engine (`libtako_core.a` in `TakoCore.xcframework`) and
TakoCoreUI come from [tako-core](https://github.com/alex09x/tako-core) at one
exact release:

- [`swift/Package.swift`](../swift/Package.swift) names the version
  (`exact:`), and [`swift/Package.resolved`](../swift/Package.resolved)
  records the commit it resolves to.
- tako-core's own `Package.swift` at that release carries the SHA-256 of
  `TakoCore.xcframework.zip`; SwiftPM refuses a download that does not match.
- The engine's Rust dependencies are locked in that release's `Cargo.lock`.

The engine library's bit-for-bit reproducibility (`SOURCE_DATE_EPOCH`,
`ZERO_AR_DATE`, `RUSTFLAGS` path remapping, built in two separate trees and
compared) is checked in tako-core by its `scripts/verify-reproducible-build.sh`.

### 1.2 The session runtime

The session runtime bundled at `Contents/Helpers/zmx` is tako-session as
tako-core released it. [`packaging/session-runtime.json`](../packaging/session-runtime.json)
pins the release tag, its commit and the SHA-256 of every downloaded file (the
executable per platform and its notices); `scripts/session_runtime.py` refuses
anything else.

### 1.3 Compiler toolchain

The Rust toolchain for `takoctl` is pinned via
[`rust-toolchain.toml`](../rust-toolchain.toml); its dependencies are locked in
[`takoctl/Cargo.lock`](../takoctl/Cargo.lock).

---

## 2. Software Bill of Materials (SBOM)

Every release ships with complete SBOM metadata in two standard formats:
1. **SPDX 2.3 JSON**: [`Tako-<version>-sbom.spdx.json`](https://spdx.dev/)
2. **CycloneDX 1.5 JSON**: [`Tako-<version>-sbom.cdx.json`](https://cyclonedx.org/)

### 2.1 SBOM Generation

SBOM files are generated from the pinned tako-core release (its `Cargo.lock`,
evaluated for the release target and features, and its `Package.swift`) via
[`scripts/generate-sbom.py`](../scripts/generate-sbom.py):

```bash
python3 scripts/generate-sbom.py --version <version> --output-dir target/macapp
```

The SBOM documents:
- Root application details (version, repository, license `MIT`, author `Alexander Panasenko`).
- All direct and transitive Rust dependencies of the engine with Package URL
  (`pkg:cargo/<name>@<version>`), download URLs, and SHA-256 crate hashes.
- The engine's binary framework with its SHA-256 checksum.
- `DEPENDS_ON` and `DESCRIBES` dependency relationship graphs.

### 2.2 Release Distribution

Release SBOMs are packaged into release archives and attached directly to each [GitHub Release](https://github.com/alex09x/tako/releases) alongside `Tako-<version>.dmg` and `Tako-<version>.zip`.
