# Mac CI and release delivery

The repository is public. Workflows use standard `macos-26` Apple Silicon
GitHub-hosted runners, not paid larger runners. Jobs are guarded against
running this configuration in a private repository. Test logs stay in the
Actions run; automatic test artifact uploads and paid cache expansion are
not enabled. Release candidates use draft GitHub Releases instead of
accumulating Actions artifact storage.

The free-compute claim applies to standard runners in this public repository.
An account-wide billing summary can also contain other repositories and products.
GitHub's `Gross amount` shows usage before discounts; `Billed amount` (`net_amount`
in a usage report) is the amount after discounts. To reconcile a charge, use the
detailed usage CSV's repository, workflow, SKU and net-amount fields, rather than
the runner's SKU name alone. See [billing report fields](https://docs.github.com/en/billing/reference/billing-reports).

## Automated checks

`ci.yml` runs on pull requests, main pushes and manual dispatch. It is also
reusable by the release workflow for an exact source commit. Engine, CLI,
Swift, application, iOS and UI stages are separate so a failure is visible
at its actual boundary. Separate end-to-end jobs run ordinary Mac interactions,
all 32 isolated persistence scenarios, the iOS surface suite and the iOS SSH
scenarios/walkthrough with its existing coverage gate. A workflow definition is not proof of execution:
inspect the run's test counts, failures and hardware-specific skips.

Checkout is pinned to the event commit (or an explicitly supplied source
commit), so retrying a pull-request run cannot silently test a newer branch.
The Swift job captures process stacks and fails after three minutes without
runtime test output; compiler output does not arm that runtime watchdog.

Swift and native application jobs install a supported Bash and expose its
path as `TAKO_TEST_BASH`, so the automatic shell-integration startup cases
run alongside the stock Bash fallback. The native job also sets that Bash as
the disposable runner account's login shell: PTY startup reads the account
record rather than trusting the launcher's `SHELL` variable. This provisioning
does not change a maintainer's shell or an installed Tako application.

The GitHub Mac is a temporary macOS VM. Xcode and ordinary macOS tools are
available, but GUI authorization and GPU/Metal behavior must be verified
by actual jobs. The native event driver also needs Accessibility trust, which
is distinct from XCUITest authorization; missing trust fails the job explicitly.
Zero executed UI tests is a failure. A hardware-dependent
skip is not a claim that its behavior was tested. The existing real test
Mac remains useful for hardware-sensitive verification.

The existing full `scripts/ci.sh` release gates, including strict lint and
coverage, remain separate from the explicitly named hosted test stages.
Workflow changes must not suppress an existing failure to obtain a green
badge.

## Download a candidate without uploading Apple credentials

Run **release-macapp → Run workflow** with:

- `mode`: `candidate`;
- `ref`: `main`, a commit in main's history, or the exact workflow commit
  explicitly selected for dispatch;
- `version`: optional numeric `X.Y.Z`; empty uses the nearest version tag.

The workflow checks that source, waits for its automated checks, compiles an
ad-hoc app and creates a **draft**, such as `candidate-123456-1`. The draft
contains an `-unsigned.zip`, `candidate.json` with source/build/checksum
metadata, and `SHA256SUMS`. It is not a signed public release and does not
replace an existing published version. Access to drafts requires repository
write access.

Download and verify it:

```sh
gh release download candidate-RUN_ID-ATTEMPT --repo alex09x/tako \
  --dir target/candidate-download
cd target/candidate-download
shasum -a 256 -c SHA256SUMS
cd ../..
ditto -x -k target/candidate-download/Tako-X.Y.Z-unsigned.zip target/candidate
```

Use the matching source checkout's maintained signing helpers. Signing does
not rebuild the downloaded executables:

```sh
python3 scripts/sign-macapp.py --app target/candidate/Tako.app \
  --candidate-metadata target/candidate-download/candidate.json --notarize
```

This selects an existing **Developer ID Application** identity from the local
keychain. `--identity` can select a name or fingerprint. Notarization uses
the existing `tako` keychain profile; choose another with `--notary-profile`.
No certificate or Apple password is exported to GitHub by this path.
Missing certificates or notarization credentials fail with an explicit error.
The tool refuses to re-sign an installed application in `/Applications`.
Before notarization, it requires a matching source checkout with clean SBOM
inputs, so a downloaded older candidate cannot acquire the current checkout's
dependency inventory or Git provenance by mistake.

Order matters: sign the bundled `zmx`, rewrite its SHA-256 in
`session-runtime.json`, sign `takoctl`, then seal and verify the app.
Never deep re-sign the app after recording the helper hash. The shared
signer is used by both the app builder and the downloaded-candidate tool.

`--notarize` runs `release-macapp.py` against that candidate directory,
notarizes and staples the app and disk image, assesses Gatekeeper, and emits
the final ZIP, DMG and SBOM files beside the app. Their hashes differ from
the unsigned input archive; distribute these final files, not the input ZIP.
Public release publication is a separate maintainer action after verification.

## Fully automatic signed releases

The signed path is triggered by a `vX.Y.Z` tag push or by manual `signed`
mode with an existing version tag. It accepts only a tag commit in main's
history and tests that exact commit before packaging. Prerelease tags can
use a suffix, such as `vX.Y.Z-beta.1`; the app's marketing version remains
the numeric `X.Y.Z` required by Apple.

Repository secrets required for this path:

| Name | Managed value |
|---|---|
| `MACOS_CERTIFICATE` | Base64 PKCS#12 Developer ID certificate with its private key |
| `MACOS_CERTIFICATE_PWD` | Password protecting that PKCS#12 file |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Developer team identifier |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

These are not needed for PR tests or unsigned candidates. Do not place them
in repository files. A signed run creates a temporary keychain, imports the
managed values without printing them, and removes that material afterward.
No signing secrets are currently implied by an unsigned candidate run.

Only after signing, notarization and verification does the workflow upload
the final assets and publish the draft. It refuses to overwrite an already
published version. `HOMEBREW_TAP_TOKEN` optionally updates the existing cask
after stable signed publication; prereleases leave the stable cask alone.
Without the token, the workflow states that the tap was
not changed.

Delete obsolete unsigned drafts once they are no longer needed, for example
`gh release delete candidate-RUN_ID-ATTEMPT --repo alex09x/tako --yes`.
Candidate drafts are prereleases, so accidentally publishing one does not make
it the stable Latest release.

## Cost and limits

Standard hosted compute is free for public repositories. Larger runners are
paid even for public projects. Actions artifact/cache storage has separate
allowances, so this workflow does not upload test artifacts by default.
Draft and public release assets use GitHub Releases; each asset must remain
under GitHub's per-file release limit.

Sources: [standard runner selection](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job),
[Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[Apple certificates in CI](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[release asset limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
