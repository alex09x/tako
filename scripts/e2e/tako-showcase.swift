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

@main
struct TakoShowcaseMain {
    static func main() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())

        if rawArgs.contains("--list") {
            print("Tako Feature Showcase Matrix:")
            print(String(repeating: "-", count: 70))
            for item in showcaseManifest {
                print(String(format: "  %-22s [%-8s] %s", item.id, item.chapter, item.feature))
                print("      Witness: \(item.witness)")
            }
            print(String(repeating: "-", count: 70))
            exit(0)
        }

        guard !rawArgs.isEmpty, !rawArgs[0].hasPrefix("-") else {
            print("Usage: tako-showcase <path-to-Tako.app> [options]")
            print("Options:")
            print("  --pace fast|presentation")
            print("  --scene <scene-id>")
            print("  --chapter core|optional|all")
            print("  --record <output.mov>")
            print("  --display")
            print("  --output-dir <path>")
            print("  --list")
            exit(1)
        }

        let appPath = rawArgs[0]
        var pacing: PacingMode = .presentation
        var scenesWanted: Set<String> = []
        var chapterWanted: String? = nil
        var recordPath: String? = nil
        var recordFullDisplay = false
        var outputDirPath: String? = nil

        var i = 1
        while i < rawArgs.count {
            switch rawArgs[i] {
            case "--pace":
                if i + 1 < rawArgs.count {
                    pacing = PacingMode(rawValue: rawArgs[i + 1]) ?? .presentation
                    i += 1
                }
            case "--scene":
                if i + 1 < rawArgs.count {
                    scenesWanted.insert(rawArgs[i + 1])
                    i += 1
                }
            case "--chapter":
                if i + 1 < rawArgs.count {
                    chapterWanted = rawArgs[i + 1]
                    i += 1
                }
            case "--record":
                if i + 1 < rawArgs.count {
                    recordPath = rawArgs[i + 1]
                    i += 1
                }
            case "--display":
                recordFullDisplay = true
            case "--output-dir":
                if i + 1 < rawArgs.count {
                    outputDirPath = rawArgs[i + 1]
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        // Allocate unique non-existing run directory
        let runId = "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))"
        let chosenOutputDir = outputDirPath ?? "target/demo-runs/\(runId)"
        let outputDirURL = URL(fileURLWithPath: chosenOutputDir)

        if outputDirPath == nil && FileManager.default.fileExists(atPath: outputDirURL.path) {
            print("FAIL: Unique output directory collision: \(outputDirURL.path)")
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        } catch {
            print("FAIL: Could not create output directory: \(error)")
            exit(1)
        }

        let bundleId = ProcessInfo.processInfo.environment["TAKO_BUNDLE_ID"] ?? "com.tako-core.terminal.showcase"
        let gitRev = ProcessInfo.processInfo.environment["TAKO_SHOWCASE_REV"] ?? "unknown"

        func persistReport(scenes: [ShowcaseSceneReport], video: VideoMetadata?, errorMsg: String?) -> Bool {
            let passed = scenes.filter { $0.status == "PASS" }.count
            let failed = scenes.filter { $0.status == "FAIL" }.count
            let skipped = scenes.filter { $0.status != "PASS" && $0.status != "FAIL" }.count

            let rep = ShowcaseReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                gitRevision: gitRev,
                appPath: appPath,
                bundleId: bundleId,
                commandOptions: rawArgs,
                pacing: pacing.rawValue,
                failedCount: failed,
                passedCount: passed,
                skippedCount: skipped,
                scenes: scenes,
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
                    "Status: \(failed == 0 ? "OK" : "FAILED")",
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
                if let v = video {
                    lines.append("")
                    lines.append("Video:")
                    lines.append("  Path: \(v.path)")
                    lines.append("  Duration: \(String(format: "%.2f", v.durationSeconds))s (Expected: \(String(format: "%.2f", v.expectedMinDuration))s)")
                    lines.append("  Resolution: \(Int(v.width))x\(Int(v.height))")
                    lines.append("  Size: \(v.fileSize) bytes")
                    lines.append("  Decoded Samples: \(v.decodedSampleCount)")
                    lines.append("  Status: \(v.status)")
                } else if recordPath != nil {
                    lines.append("")
                    lines.append("Video:")
                    lines.append("  Status: UNVERIFIED_TCC_BLOCKED")
                    lines.append("  Detail: macOS Screen Recording permission required for screencapture in non-interactive sessions; recording validation remains OPEN")
                } else {
                    lines.append("")
                    lines.append("Video: NOT_REQUESTED (non-recording run)")
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

        // Determine target scenes
        let targetScenes: [ShowcaseScene]
        if !scenesWanted.isEmpty {
            targetScenes = showcaseScenes.filter { scenesWanted.contains($0.manifest.id) }
        } else if let chapter = chapterWanted {
            if chapter == "all" {
                targetScenes = showcaseScenes
            } else {
                targetScenes = showcaseScenes.filter { $0.manifest.chapter == chapter }
            }
        } else {
            targetScenes = showcaseScenes.filter { $0.manifest.chapter == "core" }
        }

        var sceneReportMap: [String: ShowcaseSceneReport] = [:]
        for item in showcaseManifest {
            let isTarget = targetScenes.contains(where: { $0.manifest.id == item.id })
            sceneReportMap[item.id] = ShowcaseSceneReport(
                id: item.id,
                chapter: item.chapter,
                feature: item.feature,
                status: isTarget ? "PENDING" : "NOT_REQUESTED",
                durationSeconds: 0,
                evidence: isTarget ? "" : "Not requested in this run"
            )
        }

        guard AXIsProcessTrusted() else {
            let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
            _ = persistReport(scenes: reports, video: nil, errorMsg: "Accessibility permission not granted to driver process")
            print("FAIL: this process has no Accessibility permission to drive Tako UI")
            exit(1)
        }

        guard !targetScenes.isEmpty else {
            let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
            _ = persistReport(scenes: reports, video: nil, errorMsg: "No matching showcase scenes found")
            print("FAIL: No matching showcase scenes found")
            exit(2)
        }

        // Preflight recorder if requested
        var recorder: ShowcaseRecorder? = nil
        if let recPath = recordPath {
            print("==> Preflighting screen recorder...")
            do {
                try ShowcaseRecorder.preflightCheck(fullDisplay: recordFullDisplay)
                let recURL = URL(fileURLWithPath: recPath)
                recorder = try ShowcaseRecorder(targetFile: recURL, fullDisplay: recordFullDisplay)
            } catch {
                let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
                _ = persistReport(scenes: reports, video: nil, errorMsg: "Screen recording preflight error: \(error)")
                print("FAIL: Screen recording preflight error: \(error)")
                exit(1)
            }
        }

        let previouslyFront = NSWorkspace.shared.frontmostApplication
        var videoMeta: VideoMetadata? = nil
        var executionError: String? = nil

        do {
            try ShowcaseStage.validateDisplay()

            let driver = try Driver(app: URL(fileURLWithPath: appPath))
            defer { driver.quit() }
            try driver.launch(config: "window-save-state = always\nsession-persistence = true\nremote-control = on\nconfirm-close-surface = false\nmacos-titlebar-style = tabs\ntab-style = pill\nquick-terminal-position = center\n")

            // Stage initial window before recording and before scenes
            driver.activate()
            driver.setPosition(CGPoint(x: 100, y: 100))
            driver.setSize(CGSize(width: 860, height: 540))
            usleep(300_000)
            if let initialFrame = driver.windowFrame() {
                try ShowcaseStage.assertContains(window: initialFrame, name: "Initial Staged Window")
            }

            let ctx = ShowcaseContext(driver: driver, pacing: pacing, outputDir: outputDirURL)

            // Start bounded recording if requested
            if let r = recorder {
                print("==> Starting screen recording (bounded stage: \(!recordFullDisplay))...")
                try r.start()
            }

            var hasFailed = false
            for scene in targetScenes {
                if hasFailed {
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "SKIPPED",
                        durationSeconds: 0,
                        evidence: "Skipped due to previous failure"
                    )
                    continue
                }

                print("==> Scene [\(scene.manifest.chapter)]: \(scene.manifest.feature)...")
                let start = Date()
                do {
                    try scene.run(ctx)
                    let duration = Date().timeIntervalSince(start)
                    let ev = ctx.sceneTimings.last(where: { $0.scene == scene.manifest.id })?.evidence ?? "Verified postconditions"
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "PASS",
                        durationSeconds: duration,
                        evidence: ev
                    )
                } catch {
                    hasFailed = true
                    let duration = Date().timeIntervalSince(start)
                    executionError = "Scene [\(scene.manifest.id)] failed: \(error)"
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "FAIL",
                        durationSeconds: duration,
                        evidence: "\(error)"
                    )
                    print("FAIL: \(executionError!)")
                }
            }

            if let r = recorder {
                print("==> Finalizing screen recording...")
                do {
                    let totalScenesDuration = sceneReportMap.values.reduce(0.0) { $0 + $1.durationSeconds }
                    videoMeta = try r.stop(expectedMinDuration: totalScenesDuration)
                    print("Recorded showcase movie saved to: \(r.targetFile.path) (\(String(format: "%.2f", videoMeta?.durationSeconds ?? 0))s, \(videoMeta?.fileSize ?? 0) bytes, \(videoMeta?.decodedSampleCount ?? 0) frames decoded)")
                } catch {
                    executionError = "Recording finalization failed: \(error)"
                    print("FAIL: \(executionError!)")
                }
            }
        } catch {
            executionError = "Initialization error: \(error)"
            print("FAIL: \(executionError!)")
        }

        // Restore focus
        if let previouslyFront, !previouslyFront.isTerminated, let bundle = previouslyFront.bundleURL {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", bundle.path]
            try? open.run()
            open.waitUntilExit()
            previouslyFront.activate()
        }

        // Write mandatory artifacts (Finding 4)
        let finalReports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
        let writeReportOk = persistReport(scenes: finalReports, video: videoMeta, errorMsg: executionError)

        let overallSuccess = writeReportOk && executionError == nil && !finalReports.contains(where: { $0.status == "FAIL" })
        print(overallSuccess ? "Tako Showcase: OK" : "Tako Showcase: FAILED")
        exit(overallSuccess ? 0 : 1)
    }
}
