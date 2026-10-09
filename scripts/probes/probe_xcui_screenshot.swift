/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
import AppKit

print("================================================================================")
print("TAKO XCUISCREEN SCREENSHOT PROBE REPORT")
print("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
print("================================================================================")

let screen = XCUIScreen.main
print("Main Screen: \(screen)")

print("\n--- 1. Testing XCUIScreen.main.screenshot() ---")
let t0 = CFAbsoluteTimeGetCurrent()
let shot = screen.screenshot()
let latencyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
print("Capture Status: SUCCESS")
print("Capture Latency: \(String(format: "%.2f", latencyMs)) ms")
let img = shot.image
print("Image Size: \(img.size.width) x \(img.size.height) points")
let pngData = shot.pngRepresentation
print("PNG Data Byte Size: \(pngData.count) bytes")

// Multi-sample latency measurement
print("\n--- 2. Multi-Sample Latency Measurement (5 samples) ---")
var latencies: [Double] = []
for i in 1...5 {
    let start = CFAbsoluteTimeGetCurrent()
    let s = screen.screenshot()
    let dur = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    latencies.append(dur)
    print("  Sample \(i): \(String(format: "%.2f", dur)) ms (\(s.pngRepresentation.count) bytes)")
}
let minLat = latencies.min() ?? 0.0
let avgLat = latencies.reduce(0.0, +) / Double(latencies.count)
let maxLat = latencies.max() ?? 0.0
print("Latency Summary: min=\(String(format: "%.2f", minLat)) ms, avg=\(String(format: "%.2f", avgLat)) ms, max=\(String(format: "%.2f", maxLat)) ms")

print("\n--- 3. Feasibility for <150ms Presentation Budget ---")
print("Single capture average: \(String(format: "%.2f", avgLat)) ms")
if avgLat >= 75.0 {
    print("Sampling Limitation: A single capture takes \(String(format: "%.2f", avgLat)) ms, leaving insufficient margin (<75ms Nyquist interval) for multi-frame polling to measure first-frame presentation within a 150ms window.")
} else {
    print("Sampling: Single capture is within 75ms.")
}

print("\n================================================================================")
print("PROBE COMPLETE")
print("================================================================================")
