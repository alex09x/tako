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
                let idPad = item.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                let chPad = item.chapter.padding(toLength: 8, withPad: " ", startingAt: 0)
                print("  \(idPad) [\(chPad)] \(item.feature)")
                print("      Witness: \(item.witness)")
            }
            print(String(repeating: "-", count: 70))
            exit(0)
        }

        if rawArgs.contains("--self-test") {
            do {
                try ShowcaseRecorderFixtures.verifyFixtures()
                print("Showcase self-test: OK (recorder preflight fixtures passed)")
                exit(0)
            } catch {
                print("FAIL: Showcase self-test failed: \(error)")
                exit(1)
            }
        }


        guard !rawArgs.isEmpty, !rawArgs[0].hasPrefix("-") else {
            print("Usage: tako-showcase <path-to-Tako.app> [--pace fast|presentation] [--scene <id>] [--chapter core|optional|all] [--record <file>] [--display] [--output-dir <dir>] [--list]")
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
            case "--pace": if i + 1 < rawArgs.count { pacing = PacingMode(rawValue: rawArgs[i + 1]) ?? .presentation; i += 1 }
            case "--scene": if i + 1 < rawArgs.count { scenesWanted.insert(rawArgs[i + 1]); i += 1 }
            case "--chapter": if i + 1 < rawArgs.count { chapterWanted = rawArgs[i + 1]; i += 1 }
            case "--record": if i + 1 < rawArgs.count { recordPath = rawArgs[i + 1]; i += 1 }
            case "--display": recordFullDisplay = true
            case "--output-dir": if i + 1 < rawArgs.count { outputDirPath = rawArgs[i + 1]; i += 1 }
            default: break
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

        func persistReport(
            scenes: [ShowcaseSceneReport],
            video: VideoMetadata?,
            errorMsg: String?,
            recState: RecordingState,
            recReason: String?
        ) -> Bool {
            ShowcaseReport.persist(
                outputDirURL: outputDirURL,
                scenes: scenes,
                video: video,
                errorMsg: errorMsg,
                recState: recState,
                recReason: recReason,
                recordPath: recordPath,
                appPath: appPath,
                bundleId: bundleId,
                gitRev: gitRev,
                rawArgs: rawArgs,
                pacing: pacing.rawValue
            )
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

        var currentRecordingState: RecordingState = (recordPath == nil) ? .notRequested : .notRequested
        var currentRecordingReason: String? = (recordPath == nil) ? "Non-recording run" : nil

        guard AXIsProcessTrusted() else {
            let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
            _ = persistReport(
                scenes: reports,
                video: nil,
                errorMsg: "Accessibility permission not granted to driver process",
                recState: (recordPath == nil ? .notRequested : .failed),
                recReason: "Aborted due to missing Accessibility permission"
            )
            print("FAIL: this process has no Accessibility permission to drive Tako UI")
            exit(1)
        }

        guard !targetScenes.isEmpty else {
            let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
            _ = persistReport(
                scenes: reports,
                video: nil,
                errorMsg: "No matching showcase scenes found",
                recState: (recordPath == nil ? .notRequested : .failed),
                recReason: "Aborted due to missing scenes"
            )
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
            } catch let preflightErr as RecorderPreflightError {
                let recState: RecordingState
                let recReason: String
                switch preflightErr {
                case .permissionDenied(let detail):
                    recState = .tccBlocked
                    recReason = "macOS Screen Recording permission denied: \(detail)"
                case .processFailure(let exitCode, let stderr):
                    recState = .failed
                    let cleanErr = stderr.isEmpty ? "screencapture process failed" : stderr
                    recReason = "Recorder process failed (exit \(exitCode)): \(cleanErr) (permission cause unknown)"
                case .timeout(let duration):
                    recState = .failed
                    recReason = "Recorder preflight timed out after \(duration)s"
                case .invalidOutput(let detail):
                    recState = .failed
                    recReason = "Recorder preflight produced invalid output: \(detail)"
                }
                let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
                _ = persistReport(
                    scenes: reports,
                    video: nil,
                    errorMsg: "Screen recording preflight error: \(preflightErr)",
                    recState: recState,
                    recReason: recReason
                )
                print("FAIL: Screen recording preflight error: \(preflightErr)")
                exit(1)
            } catch {
                let recState: RecordingState = .failed
                let recReason = "Recorder initialization failed: \(error)"
                let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
                _ = persistReport(
                    scenes: reports,
                    video: nil,
                    errorMsg: "Screen recording initialization error: \(error)",
                    recState: recState,
                    recReason: recReason
                )
                print("FAIL: Screen recording initialization error: \(error)")
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
            guard let initialFrame = driver.windowFrame() else {
                throw Failure("Could not obtain window frame for initial staged window")
            }
            try ShowcaseStage.assertContains(window: initialFrame, name: "Initial Staged Window")

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
                    currentRecordingState = .mediaValidatedContentUnverified
                    currentRecordingReason = "Recorded movie validated (metadata + \(videoMeta?.decodedSampleCount ?? 0) decoded sample frames); semantic content acceptance OPEN"
                    print("Recorded showcase movie saved to: \(r.targetFile.path) (\(String(format: "%.2f", videoMeta?.durationSeconds ?? 0))s, \(videoMeta?.fileSize ?? 0) bytes, \(videoMeta?.decodedSampleCount ?? 0) frames decoded)")
                } catch {
                    executionError = "Recording finalization failed: \(error)"
                    currentRecordingState = .failed
                    currentRecordingReason = "Recording finalization failed: \(error)"
                    print("FAIL: \(executionError!)")
                }
            }
        } catch {
            executionError = "Initialization error: \(error)"
            if recordPath != nil && recorder != nil {
                currentRecordingState = .failed
                currentRecordingReason = "Initialization error before recording: \(error)"
            }
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

        // Write mandatory artifacts
        let finalReports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
        let writeReportOk = persistReport(
            scenes: finalReports,
            video: videoMeta,
            errorMsg: executionError,
            recState: currentRecordingState,
            recReason: currentRecordingReason
        )

        let overallSuccess = writeReportOk && executionError == nil && !finalReports.contains(where: { $0.status == "FAIL" })
        print(overallSuccess ? "Tako Showcase: OK" : "Tako Showcase: FAILED")
        exit(overallSuccess ? 0 : 1)
    }
}
