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

// MARK: - Showcase Recorder

struct VideoMetadata: Codable {
    let path: String
    let fileSize: Int64
    let durationSeconds: Double
    let width: Double
    let height: Double
    let trackCount: Int
}

final class ShowcaseRecorder {
    let targetFile: URL
    let fullDisplay: Bool
    private(set) var captureRect: CGRect?
    private var process: Process?

    init(targetFile: URL, fullDisplay: Bool = false) throws {
        self.targetFile = targetFile
        self.fullDisplay = fullDisplay

        if FileManager.default.fileExists(atPath: targetFile.path) {
            throw Failure("Record target file already exists, refusing to overwrite: \(targetFile.path)")
        }
    }

    deinit {
        cleanup()
    }

    static func preflightCheck(fullDisplay: Bool = false) throws {
        let testOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recorder_preflight_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: testOut) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if fullDisplay {
            p.arguments = ["-v", "-V", "1", testOut.path]
        } else {
            p.arguments = ["-v", "-V", "1", "-R0,0,200,200", testOut.path]
        }
        try p.run()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            throw Failure("Screen recording preflight check failed (exit code \(p.terminationStatus)). Ensure Screen Recording permission is granted.")
        }
        guard FileManager.default.fileExists(atPath: testOut.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: testOut.path),
              (attrs[.size] as? Int64 ?? 0) > 1000 else {
            throw Failure("Screen recording preflight produced empty or invalid output.")
        }
    }

    func start(for windowFrame: CGRect? = nil) throws {
        var args = ["-v"]
        if !fullDisplay {
            if let f = windowFrame {
                // Include 16pt margin around window for window border/shadow
                let originX = max(0, Int(f.origin.x) - 16)
                let originY = max(0, Int(f.origin.y) - 16)
                let width = Int(f.size.width) + 32
                let height = Int(f.size.height) + 32
                captureRect = CGRect(x: originX, y: originY, width: width, height: height)
                args.append("-R\(originX),\(originY),\(width),\(height)")
            } else {
                captureRect = CGRect(x: 100, y: 80, width: 1024, height: 768)
                args.append("-R100,80,1024,768")
            }
        }
        args.append(targetFile.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        try p.run()
        self.process = p

        // Give recorder a brief window to initialize and verify process is alive
        usleep(600_000)
        guard p.isRunning else {
            throw Failure("screencapture recorder exited prematurely (exit code \(p.terminationStatus)).")
        }
    }

    func stop() throws -> VideoMetadata {
        guard let p = process else {
            throw Failure("Cannot stop recorder: no active recording process")
        }
        defer { process = nil }

        if p.isRunning {
            p.interrupt() // SIGINT tells screencapture to finalize the QuickTime movie
            let deadline = Date().addingTimeInterval(5.0)
            while p.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if p.isRunning {
                p.terminate() // SIGTERM fallback if still hanging
                usleep(200_000)
            }
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
        guard duration > 0.1 else {
            throw Failure("Recorded video duration is invalid or zero (\(duration)s)")
        }

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw Failure("Recorded file contains no video tracks")
        }
        let trackSize = track.naturalSize
        guard trackSize.width > 0 && trackSize.height > 0 else {
            throw Failure("Recorded video has invalid frame dimensions (\(trackSize.width)x\(trackSize.height))")
        }

        return VideoMetadata(
            path: targetFile.path,
            fileSize: size,
            durationSeconds: duration,
            width: Double(trackSize.width),
            height: Double(trackSize.height),
            trackCount: videoTracks.count
        )
    }

    func cleanup() {
        if let p = process, p.isRunning {
            p.terminate()
            process = nil
        }
    }
}
