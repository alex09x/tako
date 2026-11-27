# Repository scripts

Run commands from the repository root. Build outputs, generated bindings and
run artifacts live under `target/` and are not source files.

## Development checks

Use the checks affected by the change:

```sh
./scripts/check.sh 'swift:ThemePresetStoreTests|ThemeWeightDiagnosticTests'
./scripts/check.sh e2e:theme-typography
./scripts/check.sh e2e:persist-scoped-appearance
./scripts/uitest.sh TakoFontWeightUITests
```

`check.sh` runs `check_run.py` on the test Mac through `mac-remote.sh`.
Set `TAKO_MAC` and, optionally, `TAKO_MAC_DIR` to select the host and checkout.
Swift filters are regular expressions: use `|` between alternatives. E2E
selectors use commas, such as `e2e:project-action,project-action-ui`.
Normal and persistence scenarios use their respective isolated app runners.
`uitest.sh` selects an XCUITest class or `Class/testMethod` and writes an
`.xcresult`; zero executed tests is a failure.

| Entry point | Purpose |
|---|---|
| `check.sh` / `check_run.py` | Swift filters, E2E scenarios, self-tests and iOS unit checks |
| `swift-test.sh` | Swift test runner against the pinned tako-core release |
| `selftest-macapp.sh` | Built app's event, PTY and rendering self-tests |
| `e2e-macapp.sh` | Low-level Accessibility runner against an already built test app |
| `e2e-persist.sh` | Live-session persistence journeys with separate app and session state |
| `e2e-layout.sh` | Separate crash, layout recovery and upgrade journeys |
| `uitest.sh` | Actual macOS XCUITest runner |
| `ios-unit-test.sh`, `simtest.py` | iOS simulator unit tests and app journeys |
| `motion-check.sh`, `motion-gate.sh`, `motion-mutants.py` | Motion-specific capture, gates and mutation checks |
| `ci.sh` | Explicit full multi-stage run, including lint and coverage gates |

The coverage gates remain available for Swift and iOS release work; the
engine and TakoCoreUI are tested in tako-core.
An ordinary targeted change does not require running the full CI command.

## Builds and releases

| Entry point | Purpose |
|---|---|
| `build-macapp.py` | Native macOS app; see the root README for an isolated development launch |
| `build-iosapp.py` | iOS application build |
| `tako_core.py` | The pinned tako-core release (checkout and engine framework) for the app builders |
| `session_runtime.py` | The released session runtime and its notices, checked against `packaging/session-runtime.json` |
| `release-macapp.py` | Developer ID verification, notarization and distributable macOS packaging |
| `sign-macapp.py` | Sign and optionally notarize a downloaded candidate without rebuilding it |
| `generate-sbom.py` | Supply-chain metadata for the release, from the pinned tako-core release |
| `install-iphone.sh`, `deploy-ios-testflight.sh` | Device installation and TestFlight delivery |

Use signed, notarized release artifacts for installation. A local development
bundle is a separate workflow; these entry points do not provide a production
app replacement shortcut.

Hosted Mac checks, unsigned draft downloads and optional fully signed
publication are described in [CI and release delivery](../docs/ci-and-releases.md).

## Diagnostics and manual tools

For a running app, use `takoctl diagnose --out /tmp/tako-diagnostics.json`
or **Help → Export Diagnostics**. The report redacts paths and secrets;
terminal text and microbenchmarks are explicit opt-ins. If the app cannot
start, inspect its crash report in macOS Console instead.

| Entry point | Purpose |
|---|---|
| `tako-hook.py`, `install-tako-hook.py`, `tako-codex.py`, `tako-codex.fish` | Agent hook dispatcher, installer and optional Codex launch integration; see [agent-hooks](../docs/agent-hooks.md) |
| `test_tako_hook.py` | Dispatcher fixture tests |
| `demo.sh` and `e2e/Showcase*.swift` | Feature showcase and video recording |
| `esctest.sh`, `ucs-detect.sh` | Manual terminal conformance and Unicode-width tools |
| `frame-diffs/` | Generator for committed differential-rendering fixtures |
| `probes/` | Optional host permission and signing diagnostics; see its [guide](probes/README.md) |
| `tcp_fault_proxy.py` | Fault injection for SSH and transport tests |

Manual utilities are intentionally separate from the default test and build
entry points. An unreferenced manual tool is not necessarily obsolete.
