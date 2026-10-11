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

struct ShowcaseReport: Codable {
    let timestamp: String
    let gitRevision: String
    let appPath: String
    let bundleId: String
    let commandOptions: [String]
    let pacing: String
    let failedCount: Int
    let passedCount: Int
    let skippedCount: Int
    let scenes: [ShowcaseSceneReport]
    let video: VideoMetadata?
    let error: String?
}
