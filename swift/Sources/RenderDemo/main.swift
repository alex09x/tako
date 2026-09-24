import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a terminal session to a PNG with no window server involved: proof
/// that the Rust core plus the CoreText renderer produce real pixels, and a
/// harness for eyeballing rendering changes in CI.

let core = TakoCore(cols: 84, rows: 22)

func feed(_ s: String) { core.feed(bytes: Data(s.utf8)) }

// A session that exercises the parts a screenshot should prove.
feed("\u{1b}[1;38;2;120;200;255mtako-core\u{1b}[0m \u{1b}[38;5;244m// pure Rust terminal engine\u{1b}[0m\r\n")
feed("\u{1b}[38;5;244m" + String(repeating: "─", count: 60) + "\u{1b}[0m\r\n\r\n")

feed("  \u{1b}[1;31mbold red\u{1b}[0m  \u{1b}[32mgreen\u{1b}[0m  \u{1b}[33myellow\u{1b}[0m  \u{1b}[34mblue\u{1b}[0m  \u{1b}[35mmagenta\u{1b}[0m  \u{1b}[36mcyan\u{1b}[0m\r\n")
feed("  \u{1b}[44;97m white on blue \u{1b}[0m  \u{1b}[7mreverse\u{1b}[0m  \u{1b}[3mitalic\u{1b}[0m  \u{1b}[9mstrike\u{1b}[0m  \u{1b}[4munderline\u{1b}[0m\r\n")
feed("  \u{1b}[4:3;58;2;255;120;0mcurly colored underline\u{1b}[0m   \u{1b}[53moverline\u{1b}[0m\r\n\r\n")

// 256-color ramp: one row of the color cube.
feed("  ")
for i in 16..<52 { feed("\u{1b}[48;5;\(i)m ") }
feed("\u{1b}[0m\r\n")
feed("  ")
for i in 196..<232 { feed("\u{1b}[48;5;\(i)m ") }
feed("\u{1b}[0m\r\n\r\n")

// DEC line drawing, wide chars, emoji.
feed("  \u{1b}(0lqqqqqqqqqqqqqqk\u{1b}(B   wide: 中文字符 한글   emoji: 🚀🔥\r\n")
feed("  \u{1b}(0x\u{1b}(B DEC graphics \u{1b}(0x\u{1b}(B   \u{1b}]8;;https://example.com\u{1b}\\\u{1b}[4;36mOSC 8 hyperlink\u{1b}[0m\u{1b}]8;;\u{1b}\\\r\n")
feed("  \u{1b}(0mqqqqqqqqqqqqqqj\u{1b}(B\r\n\r\n")

// A prompt marked with OSC 133, then a command and its output.
feed("\u{1b}]133;A\u{07}\u{1b}[1;32m➜\u{1b}[0m \u{1b}[1;36m~/tako-core\u{1b}[0m ")
feed("\u{1b}]133;B\u{07}cargo test\r\n")
feed("\u{1b}]133;C\u{07}\u{1b}[32m   Compiling\u{1b}[0m tako-core v0.1.0\r\n")
feed("\u{1b}[1;32mtest result: ok\u{1b}[0m. 587 passed; 0 failed; 0 ignored\r\n")
feed("\u{1b}]133;A\u{07}\u{1b}[1;32m➜\u{1b}[0m \u{1b}[1;36m~/tako-core\u{1b}[0m ")

let snapshot = core.snapshot()
let renderer = TerminalRenderer(metrics: TerminalRenderer.Metrics(fontSize: 15))
let scale: CGFloat = 2  // retina
let size = renderer.pixelSize(cols: Int(snapshot.cols), rows: Int(snapshot.rows))

guard let context = CGContext(
    data: nil,
    width: Int(size.width * scale),
    height: Int(size.height * scale),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("failed to create bitmap context\n".data(using: .utf8)!)
    exit(1)
}
context.scaleBy(x: scale, y: scale)

let frame = TerminalFrame(packed: core.viewportPacked(),
                          cols: Int(snapshot.cols), rows: Int(snapshot.rows))
renderer.draw(
    in: context,
    cols: Int(snapshot.cols),
    rows: Int(snapshot.rows),
    rowProvider: { frame.row($0) },
    cursorRow: Int(snapshot.cursorRow),
    cursorCol: Int(snapshot.cursorCol),
    cursorVisible: snapshot.cursorVisible,
    cursorStyle: snapshot.cursorStyle
)

guard let image = context.makeImage() else {
    FileHandle.standardError.write("failed to snapshot bitmap\n".data(using: .utf8)!)
    exit(1)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "terminal.png")
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("failed to create png destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

print("rendered \(snapshot.cols)x\(snapshot.rows) -> \(out.path)")
print("title: \(snapshot.title.isEmpty ? "(none)" : snapshot.title)")
print("cursor: row \(snapshot.cursorRow) col \(snapshot.cursorCol), at prompt: \(core.cursorIsAtPrompt())")
