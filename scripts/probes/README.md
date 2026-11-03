# Manual host probes

These are optional diagnostics for a new test Mac or a host-specific failure.
They are not part of the application build, default CI or release proof.
Select the probe relevant to the problem; some open a window or exercise
macOS permission APIs.

| Probe | What it inspects |
|---|---|
| `probe_host_capabilities.swift` | Native host window and capture capabilities |
| `probe_codesign_identities.sh` | Available signing identities and app signing metadata |
| `probe_notification_auth.sh` | Notification authorization and related signing context |
| `run_all_probes.sh` | Runs the three probes on the configured test Mac and packages their evidence |

`run_all_probes.sh` writes a new timestamped directory under `target/runs/`
and refuses to overwrite an existing run. Its artifacts describe that host
and run only. The normal XCUITest runner checks Automation Mode itself;
use `../uitest.sh` for real application UI tests.

The signing probe discovers the newest `TakoUITests-Runner.app` in the
standard DerivedData directory. Override it with `TAKO_XCUI_RUNNER_APP`,
or set `TAKO_XCUI_DERIVED_DATA_DIR` when Xcode uses a custom build root.
