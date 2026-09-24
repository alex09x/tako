# TakoCoreUI

The renderer that lets an app drop SwiftTerm / TakoKit entirely.

`TakoCore` (Rust, exposed through UniFFI in `TakoCore.xcframework`)
owns parsing, grid state, scrollback, selection and the input encoders.
`MetalTerminalRenderer` draws the live terminal on the GPU on both Apple
platforms. `TerminalRenderer` remains the CoreText/CoreGraphics fallback and
offscreen renderer, and `TakoTerminalView` provides the production UIKit
surface for iOS 17+.

## iOS Integration (`TakoTerminalView`)

`TakoTerminalView` is a public iOS 17+ `UIView` subclass:

```swift
import TakoCoreUI

let terminalView = TakoTerminalView(frame: bounds)
terminalView.delegate = self

// Feed PTY data
terminalView.feed(data: incomingPtyBytes)

// Implement delegate:
func terminalView(_ view: TakoTerminalView, sendInputData data: Data) {
    ptyConnection.write(data)
}
func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {
    ptyConnection.write(data)
}
func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {
    ptyConnection.resize(cols: cols, rows: rows)
}
```

## Integration

1. In an external Xcode project, add the repository URL as a Swift Package,
   pick a release, and link the `TakoCoreUI` product. The root manifest
   downloads the engine as `TakoCore.xcframework.zip` from that release and
   verifies its checksum; Xcode compiles the Metal shader resource into the
   package bundle's `default.metallib`.

2. When developing locally, build the framework and bindings first -- the
   Swift test package and the app builders use the local copy:

   ```
   ./scripts/build-xcframework.sh
   ```

   That produces `TakoCore.xcframework` (macOS + iOS device + simulator)
   and `target/bindings/tako_core.swift`. To cut a release, run
   `./scripts/package-xcframework.sh vX.Y.Z`, commit the updated
   `Package.swift`, tag it, and attach `target/TakoCore.xcframework.zip` to
   the GitHub release of that tag.

   The direct iOS and macOS app builders compile the same
   `TerminalShaders.metal` into their main bundles. `TakoTerminalView`
   selects the SwiftPM resource bundle for package builds and the main bundle
   for direct builds, so both routes use Metal rather than silently falling
   back to CoreText.

3. Fetch one atomic frame per redraw and pass that frame to the shared Metal
   renderer. Do not assemble a frame from a separate snapshot and per-row FFI
   calls:

   ```swift
   let frame = core.renderFrame()
   metalRenderer.planner.isFocused = surfaceIsFocused
   metalRenderer.planner.cursorBlinkPhaseOn = cursorBlinkPhaseOn
   let statistics = metalRenderer.render(frame: frame, in: metalLayer)
   ```

   `FfiRenderFrame` contains matching geometry, cursor, selection, damage and
   packed viewport data under one Rust lock. iOS coalesces damage with a
   display link; macOS invalidates its layer directly. Both suppress partial
   frames while synchronized output mode is active.

   Kitty image geometry and identity come from
   `core.graphicsImageMetadata(imageId:)`. The renderer crosses that FFI once
   per live image ID and frame, and requests the full pixel payload only when
   the image first appears or its generation changes. Glyph atlas updates use
   copy-on-write Metal textures so an in-flight command buffer never samples a
   page while the CPU replaces it.

4. Input goes back through the core, never hand-built:

   ```swift
   ptyWrite(core.encodeKey(event: keyEvent))
   ptyWrite(core.encodeMouse(event: mouseEvent))
   ptyWrite(core.encodePaste(text: pasteboardText))
   ptyWrite(core.takeOutput())   // DA/DSR/DECRQSS replies the app must echo
   ```

5. Host-visible effects (bell, clipboard, notifications, working directory,
   progress) arrive as `core.takeEvents()`.

## Offscreen proof

`Sources/RenderDemo` renders a session to a PNG with no window server, which
doubles as a rendering regression harness:

```
swiftc -O target/bindings/tako_core.swift \
  swift/Sources/TakoCoreUI/TerminalRenderer.swift \
  swift/Sources/RenderDemo/main.swift \
  -Xcc -fmodule-map-file=$PWD/target/bindings/tako_coreFFI.modulemap \
  -I target/bindings -L target/macos -ltako_core \
  -framework CoreGraphics -framework CoreText -framework ImageIO \
  -framework UniformTypeIdentifiers -o /tmp/render_demo
/tmp/render_demo terminal.png
```

## Running the macOS app

The direct build compiles the Rust core, generated UniFFI bindings, upstream
AppKit surface, shared renderer and Metal shaders into one signed app bundle:

```
python3 scripts/build-macapp.py
open target/macapp/Tako.app
```

The live surface obtains one `FfiRenderFrame` per redraw and gives Metal
ordinary backgrounds, selection, glyphs, cursor and Kitty images. The
transparent CoreText layer is used for IME marked text. It draws the complete
terminal only for an explicit fallback: Metal is unavailable, the configured
window background is translucent, or the view is temporarily too small for a
nonzero Metal drawable.
