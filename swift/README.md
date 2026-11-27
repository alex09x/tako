# Tako's Swift package

The macOS app layer (`Sources/TakoApp`, `Sources/TakoKit`, `Sources/TakoObjC`),
the iOS app's sources (`Sources/iOSApp`) and their tests (`Tests/TakoTests`).

The terminal engine and its views -- `TakoTerminalNSView`,
`TakoTerminalView`, the Metal renderer and the CoreText fallback -- are
`TakoCoreUI` from [tako-core](https://github.com/alex09x/tako-core), at the
one exact release `Package.swift` names; `Package.resolved` records its
commit, and SwiftPM checks the engine framework's checksum. Their
documentation, integration guide and tests are in tako-core.

## Tests

```sh
../scripts/swift-test.sh                       # everything, serially
../scripts/check.sh 'swift:ThemePresetStoreTests'   # one filter, on the test Mac
```

## Running the macOS app

`scripts/build-macapp.py` builds the signed app bundle with `swiftc`
directly, from the same tako-core release (see
[../ARCHITECTURE.md](../ARCHITECTURE.md)). Use the isolated development
bundle and profile in the root [Build & Run](../README.md#build--run)
instructions.

## Rendering verification

The running app can export a pane's offscreen-rendered frame:

```sh
takoctl screenshot --target active --out terminal.png
```

This is the app-side rendered image, not a capture of the displayed Metal
window. Actual window-pixel checks live in `../macos_uitests`.
