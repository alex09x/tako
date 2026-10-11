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
import Foundation

// MARK: - Showcase Pacing & Settings

enum PacingMode: String, Codable {
    case fast
    case presentation
}

struct ShowcaseOptions {
    var appPath: String
    var bundleId: String = ""
    var pacing: PacingMode = .presentation
    var scenesWanted: Set<String> = []
    var chapterWanted: String? = nil
    var recordPath: String? = nil
    var recordFullDisplay: Bool = false
    var outputDir: URL
    var rawArguments: [String] = []
}

// MARK: - Scene Definition & Matrix

enum SceneStatus: String, Codable {
    case supported = "SUPPORTED"
    case pending = "PENDING"
    case blocked = "BLOCKED"
}

struct SceneManifestItem: Codable {
    let id: String
    let chapter: String
    let feature: String
    let witness: String
    let status: SceneStatus
}

let showcaseManifest: [SceneManifestItem] = [
    SceneManifestItem(
        id: "welcome",
        chapter: "core",
        feature: "Launch & 24-bit TrueColor Engine",
        witness: "24-bit ANSI color rendering, interactive shell readiness, banner visibility",
        status: .supported
    ),
    SceneManifestItem(
        id: "splits",
        chapter: "core",
        feature: "Split Panes & Keyboard Navigation",
        witness: "Cmd+D horizontal split, Cmd+] pane cycling, independent TTY delivery, Cmd+W closure",
        status: .supported
    ),
    SceneManifestItem(
        id: "workspaces-frame-sync",
        chapter: "core",
        feature: "Multi-Workspace & Live Window Frame Sync",
        witness: "Pill navigation, new workspace dialog, frame independence when off, live sync when enabled",
        status: .supported
    ),
    SceneManifestItem(
        id: "tabs-pills",
        chapter: "core",
        feature: "Native Tabs & Pill Styling",
        witness: "Cmd+T tab creation, Cmd+1/2 switching, per-tab TTY isolation, Cmd+W clean closure",
        status: .supported
    ),
    SceneManifestItem(
        id: "persistence",
        chapter: "core",
        feature: "Process Continuity & Session Persistence",
        witness: "Active background counter survives app quit/relaunch and continues in reattached PTY",
        status: .supported
    ),
    SceneManifestItem(
        id: "quick-terminal",
        chapter: "optional",
        feature: "Quake-Style Quick Terminal Dropdown",
        witness: "Cmd+Shift+` toggle, Quick Terminal discovery via takoctl tree, clean dismissal",
        status: .supported
    ),
    SceneManifestItem(
        id: "zoom",
        chapter: "optional",
        feature: "Dynamic Font Zooming & Column Reflow",
        witness: "Cmd+= increases font / decreases cols, Cmd+0 resets columns",
        status: .supported
    ),
]

final class ShowcaseContext {
    let driver: Driver
    let pacing: PacingMode
    let outputDir: URL
    private(set) var sceneTimings: [(scene: String, duration: Double, status: String, evidence: String)] = []

    init(driver: Driver, pacing: PacingMode, outputDir: URL) {
        self.driver = driver
        self.pacing = pacing
        self.outputDir = outputDir
    }

    func typeNaturally(_ text: String, cpm: Double = 600) throws {
        if pacing == .fast {
            try driver.type(text)
            return
        }
        let intervalMicroseconds = useconds_t(max(10_000, 60_000_000 / cpm))
        for ch in text {
            try driver.type(String(ch))
            usleep(intervalMicroseconds)
        }
    }

    func viewerPause(_ seconds: Double) {
        guard pacing == .presentation else {
            usleep(50_000)
            return
        }
        usleep(useconds_t(seconds * 1_000_000))
    }

    func recordTiming(scene: String, duration: Double, status: String, evidence: String = "") {
        sceneTimings.append((scene: scene, duration: duration, status: status, evidence: evidence))
    }
}

typealias ShowcaseAction = (ShowcaseContext) throws -> Void

struct ShowcaseScene {
    let manifest: SceneManifestItem
    let run: ShowcaseAction
}

// MARK: - Reports & Artifacts

struct ShowcaseSceneReport: Codable {
    let id: String
    let chapter: String
    let feature: String
    let status: String
    let durationSeconds: Double
    let evidence: String
}

enum RecordingState: String, Codable {
    case notRequested = "NOT_REQUESTED"
    case tccBlocked = "UNVERIFIED_TCC_BLOCKED"
    case failed = "FAILED"
    case mediaValidatedContentUnverified = "MEDIA_VALIDATED_CONTENT_UNVERIFIED"
}

// MARK: - Preflight Errors

enum RecorderPreflightError: Error, Equatable, CustomStringConvertible {
    case permissionDenied(detail: String)
    case timeout(duration: Double)
    case processFailure(exitCode: Int32, stderr: String)
    case invalidOutput(detail: String)

    var description: String {
        switch self {
        case .permissionDenied(let detail):
            return "Screen Recording permission denied: \(detail)"
        case .timeout(let duration):
            return "Screen recording preflight timed out after \(duration)s"
        case .processFailure(let exitCode, let stderr):
            let msg = stderr.isEmpty ? "unknown error" : stderr
            return "Screen recording process failed (exit \(exitCode)): \(msg)"
        case .invalidOutput(let detail):
            return "Screen recording produced invalid output: \(detail)"
        }
    }
}

struct ShowcaseRecordingReport: Codable {
    let state: RecordingState
    let targetPath: String?
    let reason: String?
    let video: VideoMetadata?
}

struct ShowcaseReport: Codable {
    let timestamp: String
    let gitRevision: String
    let appPath: String
    let bundleId: String
    let commandOptions: [String]
    let pacing: String
    let status: String
    let failedCount: Int
    let passedCount: Int
    let skippedCount: Int
    let scenes: [ShowcaseSceneReport]
    let recording: ShowcaseRecordingReport
    let video: VideoMetadata?
    let error: String?

    static func persist(
        outputDirURL: URL,
        scenes: [ShowcaseSceneReport],
        video: VideoMetadata?,
        errorMsg: String?,
        recState: RecordingState,
        recReason: String?,
        recordPath: String?,
        appPath: String,
        bundleId: String,
        gitRev: String,
        rawArgs: [String],
        pacing: String
    ) -> Bool {
        let passed = scenes.filter { $0.status == "PASS" }.count
        let failed = scenes.filter { $0.status == "FAIL" }.count
        let skipped = scenes.filter { $0.status != "PASS" && $0.status != "FAIL" }.count
        let overallStatus = (failed == 0 && errorMsg == nil) ? "OK" : "FAILED"

        let recReport = ShowcaseRecordingReport(
            state: recState,
            targetPath: recordPath,
            reason: recReason,
            video: video
        )

        let rep = ShowcaseReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            gitRevision: gitRev,
            appPath: appPath,
            bundleId: bundleId,
            commandOptions: rawArgs,
            pacing: pacing,
            status: overallStatus,
            failedCount: failed,
            passedCount: passed,
            skippedCount: skipped,
            scenes: scenes,
            recording: recReport,
            video: video,
            error: errorMsg
        )

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(rep)
            try data.write(to: outputDirURL.appendingPathComponent("showcase_report.json"))

            var lines = [
                "Tako Showcase Report",
                "Timestamp: \(rep.timestamp)",
                "Revision: \(rep.gitRevision)",
                "App: \(rep.appPath) (Bundle: \(rep.bundleId))",
                "Pacing: \(rep.pacing)",
                "Status: \(overallStatus)",
                "Passed: \(passed), Failed: \(failed), Skipped/Unrequested: \(skipped)",
                "",
                "Scenes:",
            ]
            for s in scenes {
                lines.append("  [\(s.status)] \(s.id) (\(String(format: "%.2f", s.durationSeconds))s) - \(s.feature)")
                if !s.evidence.isEmpty {
                    lines.append("    Evidence: \(s.evidence)")
                }
            }
            lines.append("")
            lines.append("Recording:")
            lines.append("  State: \(recReport.state.rawValue)")
            if let reason = recReport.reason {
                lines.append("  Reason: \(reason)")
            }
            if let v = video {
                lines.append("  Path: \(v.path)")
                lines.append("  Duration: \(String(format: "%.2f", v.durationSeconds))s (Expected: \(String(format: "%.2f", v.expectedMinDuration))s)")
                lines.append("  Resolution: \(Int(v.width))x\(Int(v.height))")
                lines.append("  Size: \(v.fileSize) bytes")
                lines.append("  Decoded Samples: \(v.decodedSampleCount)")
                lines.append("  Status: \(v.status)")
            }
            if let err = errorMsg {
                lines.append("")
                lines.append("Error: \(err)")
            }
            try lines.joined(separator: "\n").write(to: outputDirURL.appendingPathComponent("showcase_report.txt"), atomically: true, encoding: .utf8)
            print("Showcase artifacts written to: \(outputDirURL.path)")
            return true
        } catch {
            print("FAIL: Failed to persist showcase artifacts: \(error)")
            return false
        }
    }
}

// MARK: - Recorder Preflight Fixtures

struct ShowcaseRecorderFixtures {
    static func verifyFixtures() throws {
        // Fixture 1: Permission denial via API (probe process itself lacks permission)
        let apiDenial = ShowcaseRecorder.classifyPreflightResult(
            terminationStatus: 0,
            stderr: "",
            hasPermission: false
        )
        guard case .failure(.permissionDenied) = apiDenial else {
            throw Failure("Fixture error: permission API denial must classify as permissionDenied")
        }

        // Fixture 2: Permission denial via explicit diagnostic in child process stderr
        let diagDenial = ShowcaseRecorder.classifyPreflightResult(
            terminationStatus: 1,
            stderr: "screencapture: not permitted to capture display contents",
            hasPermission: true
        )
        guard case .failure(.permissionDenied) = diagDenial else {
            throw Failure("Fixture error: stderr with explicit permission denial must classify as permissionDenied")
        }

        // Fixture 3: hasPermission=true with kCGErrorCannotComplete must classify as processFailure (NOT permissionDenied)
        let cgErrorCannotComplete = ShowcaseRecorder.classifyPreflightResult(
            terminationStatus: 1,
            stderr: "screencapture: [error] kCGErrorCannotComplete: operation inappropriate for current system state",
            hasPermission: true
        )
        guard case .failure(.processFailure(exitCode: 1, stderr: let err)) = cgErrorCannotComplete,
              err.contains("kCGErrorCannotComplete") else {
            throw Failure("Fixture error: kCGErrorCannotComplete must classify as processFailure (permission cause unknown)")
        }

        // Fixture 4: hasPermission=true with non-permission 'screen recording' text must classify as processFailure (NOT permissionDenied)
        let nonPermissionText = ShowcaseRecorder.classifyPreflightResult(
            terminationStatus: 1,
            stderr: "screencapture: failed to initialize screen recording compressor pipeline",
            hasPermission: true
        )
        guard case .failure(.processFailure(exitCode: 1, stderr: let err)) = nonPermissionText,
              err.contains("screen recording compressor pipeline") else {
            throw Failure("Fixture error: non-permission screen recording error must classify as processFailure")
        }

        // Fixture 5: Unrelated nonzero recorder exit (preserves raw exit code and stderr, permission cause unknown)
        let unrelatedExit = ShowcaseRecorder.classifyPreflightResult(
            terminationStatus: 2,
            stderr: "screencapture: illegal option -- z",
            hasPermission: true
        )
        guard case .failure(.processFailure(exitCode: 2, stderr: let err)) = unrelatedExit,
              err.contains("illegal option") else {
            throw Failure("Fixture error: unrelated nonzero exit must classify as processFailure")
        }

        // Fixture 6: Subprocess fixture with simulated permission denial
        do {
            try ShowcaseRecorder.preflightCheck(
                permissionChecker: { false }
            )
            throw Failure("Fixture error: preflightCheck with permissionChecker=false must throw")
        } catch let err as RecorderPreflightError {
            guard case .permissionDenied = err else {
                throw Failure("Fixture error: expected permissionDenied, got: \(err)")
            }
        }

        // Fixture 7: Subprocess fixture with unrelated nonzero exit (/usr/bin/false)
        do {
            try ShowcaseRecorder.preflightCheck(
                permissionChecker: { true },
                executableURL: URL(fileURLWithPath: "/usr/bin/false")
            )
            throw Failure("Fixture error: preflightCheck with /usr/bin/false must throw")
        } catch let err as RecorderPreflightError {
            guard case .processFailure(exitCode: let code, _) = err, code != 0 else {
                throw Failure("Fixture error: expected processFailure with nonzero exit, got: \(err)")
            }
        }
    }
}



