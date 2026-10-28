/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

/// Run the actual Kitty client inside the terminal and inspect its rendered
/// result. The caller supplies the executable so ordinary E2E needs no Kitty.
func runKittyIcatScenario(_ d: Driver) throws {
    guard let kitten = ProcessInfo.processInfo.environment["TAKO_E2E_KITTEN"],
          FileManager.default.isExecutableFile(atPath: kitten) else {
        throw Failure("kitty-icat requires TAKO_E2E_KITTEN pointing to the kitten executable")
    }
    func makeImage(name: String, side: Int, red: UInt8, green: UInt8) throws -> String {
        let path = d.path(name)
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0), let bytes = image.bitmapData else {
            throw Failure("could not create the image")
        }
        for y in 0..<side {
            for x in 0..<side {
                let offset = y * image.bytesPerRow + x * 4
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = 255
                bytes[offset + 3] = 255
            }
        }
        guard let png = image.representation(using: .png, properties: [:]) else { throw Failure("could not encode the image") }
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func show(_ image: String, name: String, options: String, cyan: Bool) throws {
        let statusName = "\(name)-status"
        let command = "\(quote(kitten)) icat --stdin=no \(options) \(quote(image)); printf '%s' $? > \(quote(d.path(statusName)))"
        try d.run("/bin/sh -c \(quote(command))")
        let status = try d.file(statusName, timeout: 30).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == "0" else { throw Failure("kitten icat \(name) exited \(status); screen: \(d.screenText().suffix(400))") }
        let screenshot = d.path("\(name)-screen.png")
        let ctl = quote(d.appURL.appendingPathComponent("Contents/MacOS/takoctl").path)
        _ = try d.exec("\(ctl) --bundle-id \(quote(d.bundleID)) screenshot --out \(quote(screenshot))")
        let screenshotData = try Data(contentsOf: URL(fileURLWithPath: screenshot))
        guard let bitmap = NSBitmapImageRep(data: screenshotData) else { throw Failure("could not read terminal screenshot") }
        var colored = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.blueComponent > 0.85 && (cyan
                    ? color.redComponent < 0.15 && color.greenComponent > 0.85
                    : color.redComponent > 0.85 && color.greenComponent < 0.15) { colored += 1 }
            }
        }
        if colored < 100 {
            let evidence = URL(fileURLWithPath: kitten).deletingLastPathComponent().appendingPathComponent("\(name)-failure.png")
            try screenshotData.write(to: evidence)
            throw Failure("kitten \(name) exited successfully but the image was not visible (\(colored) pixels; screenshot: \(evidence.path); screen: \(d.screenText().suffix(400)))")
        }
    }
    try show(makeImage(name: "icat-magenta.png", side: 32, red: 255, green: 0), name: "icat-normal", options: "", cyan: false)
    // Resizing this larger image makes kitten transmit zlib-compressed RGB.
    try show(makeImage(name: "icat-cyan.png", side: 128, red: 0, green: 255), name: "icat-placed", options: "--place=4x3@0x0", cyan: true)
    try d.run("echo icat-input-ok > \(quote(d.path("icat-input")))")
    try d.expect("icat-input", "icat-input-ok\n", "terminal input after kitten icat")
}
