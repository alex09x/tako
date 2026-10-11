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
import ApplicationServices
import AVFoundation
import Foundation

// MARK: - Showcase Presentation Stage

/// Bounding stage geometry within which all showcase windows and UI elements must reside.
struct ShowcaseStage {
    static var bounds: CGRect {
        if let screen = NSScreen.main {
            let marginX: CGFloat = 40
            let marginY: CGFloat = 40
            let width = min(1400, screen.frame.width - (marginX * 2))
            let height = min(860, screen.frame.height - (marginY * 2))
            let x = round((screen.frame.width - width) / 2)
            let y: CGFloat = marginY
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return CGRect(x: 40, y: 40, width: 1240, height: 780)
    }

    static func validateDisplay(screen: NSScreen? = NSScreen.main) throws {
        guard let screen = screen else {
            throw Failure("No active display found to validate showcase stage")
        }
        let screenRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        guard screenRect.contains(bounds) else {
            throw Failure("Showcase stage \(bounds) exceeds display bounds \(screenRect)")
        }
    }

    static func assertContains(window: CGRect, name: String) throws {
        guard bounds.contains(window) else {
            throw Failure("Window '\(name)' bounds (\(window)) exceed defined showcase stage (\(bounds))")
        }
    }
}

// MARK: - Video Metadata

struct VideoMetadata: Codable {
    let path: String
    let fileSize: Int64
    let durationSeconds: Double
    let expectedMinDuration: Double
    let width: Double
    let height: Double
    let trackCount: Int
    let decodedSampleCount: Int
    let status: String
}

// MARK: - Showcase Recorder

final class ShowcaseRecorder {
    let targetFile: URL
    let fullDisplay: Bool
    let captureRect: CGRect
    private var process: Process?
    private let errorPipe = Pipe()
    private var startTime: Date?

    init(targetFile: URL, fullDisplay: Bool = false, customStage: CGRect? = nil) throws {
        self.targetFile = targetFile
        self.fullDisplay = fullDisplay
        self.captureRect = customStage ?? ShowcaseStage.bounds

        if FileManager.default.fileExists(atPath: targetFile.path) {
            throw Failure("Record target file already exists, refusing to overwrite: \(targetFile.path)")
        }
    }

    deinit {
        cleanup()
    }

    static func preflightCheck(fullDisplay: Bool = false, stage: CGRect = ShowcaseStage.bounds) throws {
        let testOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recorder_preflight_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: testOut) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if fullDisplay {
            p.arguments = ["-v", "-V", "1", testOut.path]
        } else {
            p.arguments = ["-v", "-V", "1", "-R\(Int(stage.origin.x)),\(Int(stage.origin.y)),\(Int(stage.size.width)),\(Int(stage.size.height))", testOut.path]
        }
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()

        // Bounded preflight wait with deadline escalation
        let deadline = Date().addingTimeInterval(5.0)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if p.isRunning {
            p.terminate()
            usleep(200_000)
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
            p.waitUntilExit()
            throw Failure("Screen recording preflight timed out after 5.0s")
        }
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure("Screen recording preflight check failed (exit \(p.terminationStatus)): \(errStr). Ensure Screen Recording permission is granted.")
        }
        guard FileManager.default.fileExists(atPath: testOut.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: testOut.path),
              (attrs[.size] as? Int64 ?? 0) > 1000 else {
            throw Failure("Screen recording preflight produced empty or invalid output.")
        }
    }

    func start() throws {
        var args = ["-v"]
        if !fullDisplay {
            args.append("-R\(Int(captureRect.origin.x)),\(Int(captureRect.origin.y)),\(Int(captureRect.size.width)),\(Int(captureRect.size.height))")
        }
        args.append(targetFile.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.standardError = errorPipe
        try p.run()
        self.process = p
        self.startTime = Date()

        // Bounded startup check: wait up to 1.5s for process to initialize and confirm running
        let startDeadline = Date().addingTimeInterval(1.5)
        while Date() < startDeadline {
            if !p.isRunning {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw Failure("screencapture recorder exited prematurely (exit \(p.terminationStatus)): \(errStr)")
            }
            usleep(150_000)
        }
    }

    func stop(expectedMinDuration: Double = 0.0) throws -> VideoMetadata {
        guard let p = process else {
            throw Failure("Cannot stop recorder: no active recording process")
        }
        defer {
            process = nil
        }

        // Check if process terminated prematurely before stop was requested
        if !p.isRunning {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure("screencapture recorder died unexpectedly before stop (exit code \(p.terminationStatus)): \(errStr)")
        }

        p.interrupt() // SIGINT tells screencapture to finalize the QuickTime movie
        let stopDeadline = Date().addingTimeInterval(5.0)
        while p.isRunning && Date() < stopDeadline {
            usleep(100_000)
        }
        if p.isRunning {
            p.terminate() // SIGTERM escalation
            let termDeadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < termDeadline {
                usleep(100_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                usleep(100_000)
            }
        }
        p.waitUntilExit() // Reaped child guaranteed

        guard p.terminationStatus == 0 else {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure("screencapture terminated abnormally with exit code \(p.terminationStatus): \(errStr)")
        }

        // Bounded verification of the produced video file
        guard FileManager.default.fileExists(atPath: targetFile.path) else {
            throw Failure("Recorded video file was not created at \(targetFile.path)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: targetFile.path)
        guard let size = attrs[.size] as? Int64, size > 10_000 else {
            throw Failure("Recorded video file is empty or corrupted (size: \(attrs[.size] ?? 0) bytes)")
        }

        let asset = AVURLAsset(url: targetFile)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0.5 else {
            throw Failure("Recorded video duration is invalid or too short (\(duration)s)")
        }

        // Require video duration to cover executed scenes
        if expectedMinDuration > 0.0 {
            guard duration >= expectedMinDuration * 0.85 else {
                throw Failure("Recorded video duration (\(duration)s) is significantly shorter than expected scene runtime (\(expectedMinDuration)s)")
            }
        }

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw Failure("Recorded file contains no video tracks")
        }
        let trackSize = track.naturalSize
        guard trackSize.width > 0 && trackSize.height > 0 else {
            throw Failure("Recorded video has invalid frame dimensions (\(trackSize.width)x\(trackSize.height))")
        }

        // Decode representative frames spanning the entire video duration to prove media validity
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        let sampleCheckpoints: [Double] = [0.1, 0.25, 0.5, 0.75, 0.9].map { $0 * duration }
        var decodedCount = 0
        for sampleTimeSec in sampleCheckpoints {
            let sampleTime = CMTime(seconds: sampleTimeSec, preferredTimescale: 600)
            var actualTime = CMTime.zero
            let sampleImage = try imageGenerator.copyCGImage(at: sampleTime, actualTime: &actualTime)
            guard sampleImage.width > 0 && sampleImage.height > 0 else {
                throw Failure("Failed to decode video frame at \(sampleTimeSec)s from recorded movie asset")
            }
            decodedCount += 1
        }

        return VideoMetadata(
            path: targetFile.path,
            fileSize: size,
            durationSeconds: duration,
            expectedMinDuration: expectedMinDuration,
            width: Double(trackSize.width),
            height: Double(trackSize.height),
            trackCount: videoTracks.count,
            decodedSampleCount: decodedCount,
            status: "RECORDING_VERIFIED"
        )
    }

    func cleanup() {
        if let p = process {
            if p.isRunning {
                p.terminate()
                usleep(100_000)
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                    usleep(100_000)
                }
            }
            p.waitUntilExit()
            process = nil
        }
    }
}
