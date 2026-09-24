# macOS UI tests

The upstream XCUITest suite, ported to Tako. These tests drive a real
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
| `TakoUITests/` | The 8 upstream source files, byte-identical to upstream |
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
(`com.tako-core.terminal`), and the UI test target sets
`TEST_TARGET_NAME = TakoCore`, which is what puts `UITargetAppPath` into the
generated `.xctestrun`.

If `scripts/build-macapp.py` fails, the script phase emits a warning and keeps
the placeholder rather than failing the build. Compiling the tests is the point
of this project and is deliberately not held hostage to the app build; the
tests skip themselves outside a manual Xcode run anyway (below).

## Building and running

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

## Why these tests do nothing on CI

`TakoCustomConfigCase` overrides `defaultTestSuite` to return an empty
suite unless `IDE_DISABLED_OS_ACTIVITY_DT_MODE` is set in the environment --
a variable Xcode's IDE sets and `xcodebuild` does not. That is upstream's own
behaviour, kept verbatim: these tests are slow and click-driven, and upstream's
CI does not run them either. Removing the skip would make them run, and hang or
fail, in exactly the contexts upstream never intended.

Running them for real therefore needs Xcode itself, plus:

- a logged-in, unlocked GUI session on a real (not headless) display,
- Accessibility and Automation permission granted to Xcode, otherwise the
  runner dies with `Timed out while enabling automation mode`,
- no other app stealing focus, since the tests type keystrokes and drag tabs.
