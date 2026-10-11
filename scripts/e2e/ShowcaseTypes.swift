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
}
