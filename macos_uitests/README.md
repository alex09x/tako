# macOS UI tests

The upstream XCUITest suite, ported to Tako, plus Tako's feature journeys. These tests drive a real
running app through the accessibility tree -- windows, tabs, menu items, the
command palette, titlebar pixels.

They live here, outside `swift/`, and not in `swift/Package.swift`, for one
reason: SwiftPM has no UI-Testing-Bundle target kind at all. Only a real Xcode
project can host one. (And a stray directory under `swift/Sources` or
`swift/Tests` breaks SwiftPM's own resolution -- see `swift/Package.swift`.)

## Layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen spec; the `.xcodeproj` below is generated from it |
| `TakoUITests.xcodeproj` | Generated. Committed, so no tool is needed to build |
| `TakoUITests/` | Upstream compatibility cases and first-party feature journeys |
| `AppHost/main.swift` | Placeholder entry point for the host-app target |

The eight files under `TakoUITests/` are upstream's
`macos/TakoUITests/`: `TakoCustomConfigCase.swift` (the base class),
`AppKitExtensions.swift` (luminance helpers), and the six test files --
command palette, mouse state, theme, title, titlebar tabs, window position.

## How the host application is wired

XCUITest needs a *Target Application*: a real Xcode app target whose product it
launches for a bare `XCUIApplication()`. This repo's app is not built by Xcode
-- it is built by `scripts/build-macapp.py`. So the `TakoCore` target here is a
native macOS app target that exists only as a wrapper:

1. It compiles `AppHost/main.swift`, a placeholder, so the target links.
2. A post-build script phase runs `python3 scripts/build-macapp.py` from the
   repo root and `ditto`s the resulting `target/macapp/Tako.app` over its
   own product in `BUILT_PRODUCTS_DIR`, replacing the placeholder wholesale.

Its `PRODUCT_BUNDLE_IDENTIFIER` matches the real bundle's
(`com.tako-core.terminal.uitest`, separate from the installed application), and the UI test target sets
`TEST_TARGET_NAME = TakoCore`, which is what puts `UITargetAppPath` into the
generated `.xctestrun`.

If `scripts/build-macapp.py` fails, the script phase emits a warning and keeps
the placeholder rather than failing the build. Compiling the tests is the point
of this project and is deliberately not held hostage to the app build; the
tests skip themselves outside a manual Xcode run anyway (below).

## Building and running

Run the focused appearance cases on the remote test Mac:

```sh
scripts/uitest.sh TakoScopedAppearanceUITests TakoThemePresetUITests
```

This uses the `TakoUITests-Run` scheme, which enables test discovery, holds the shared GUI lock,
and rejects a run with zero passed cases. The seven tests check scoped menus and containment,
rendered theme/reset pixels, independent split panes, rendered font geometry and glyphs,
full-preset preview/cancel, save/relaunch/reopen, invalid names and failed writes. Screenshots
are retained in `target/uitest.xcresult` as supporting evidence. Each fixture uses an isolated
config, defaults and test-bundle state; it restores any prior test profile and does not use the
installed app's bundle or sessions.

To prepare the exact runner without executing UI tests:

```sh
scripts/uitest.sh --build-only TakoScopedAppearanceUITests TakoThemePresetUITests
```

This is explicitly **compilation only**, not a passing UI run. The wrapper also fails if the
real host app was not built and Xcode kept the placeholder.

```
xcodebuild build-for-testing -project macos_uitests/TakoUITests.xcodeproj \
    -scheme TakoUITests -destination platform=macOS
xcodebuild test -project macos_uitests/TakoUITests.xcodeproj \
    -scheme TakoUITests -destination platform=macOS
```

Regenerate the project after editing `project.yml`:

```
cd macos_uitests && xcodegen generate
```

## Real execution and test isolation

Both schemes run real tests; `-Run` remains the name used by the existing
scripts. Use `build-for-testing` for compilation without desktop interaction.
Running the tests needs:

- a logged-in, unlocked GUI session on a real (not headless) display,
- Accessibility and Automation permission granted to Xcode, otherwise the
  runner dies with `Timed out while enabling automation mode`,
- no other app stealing focus, since the tests type keystrokes and drag tabs.

The sandboxed test runner has narrowly scoped entitlements for the `.uitest`
profile, its two test preference domains, and `/private/tmp/tkui/`. The base
fixture clears that test state before and after each case, with a separate
session directory per case. Ordinary interaction tests disable session
persistence; the persistence runner tests that separately. State remains
available across launches inside a single case.

These permissions belong to the UI-test target. To roll them back, remove
its `CODE_SIGN_ENTITLEMENTS` setting and `TakoUITests.entitlements`, then
rebuild the test target. Production app entitlements are independent.

If `/usr/bin/automationmodetool status` reports that Automation Mode is disabled and enabling
it requires user authentication, the wrapper fails before running any test and says so. An
authorized CI host that allows activation without repeated authentication proceeds normally;
the test runner enables its own automation session. Administrator authorization on the test Mac is a
system prerequisite; it must not be bypassed or counted as successful execution. The existing
isolated AX/CGEvent journeys (`settings-theme-presets`, `settings-appearance`,
`persist-scoped-appearance`) are a separate executable UI gate, not XCUITest results.
