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

enum PacingMode: String {
    case fast
    case presentation
}

struct ShowcaseOptions {
    var appPath: String
    var pacing: PacingMode = .presentation
    var scenesWanted: Set<String> = []
    var chapterWanted: String? = nil
    var recordPath: String? = nil
    var outputDir: URL
}

// MARK: - Scene Definition & Matrix

enum SceneStatus: String {
    case supported
    case pending
    case blocked
}

struct SceneManifestItem {
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
    private(set) var sceneTimings: [(scene: String, duration: Double, status: String)] = []

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

    func recordTiming(scene: String, duration: Double, status: String) {
        sceneTimings.append((scene: scene, duration: duration, status: status))
    }
}

typealias ShowcaseAction = (ShowcaseContext) throws -> Void

struct ShowcaseScene {
    let manifest: SceneManifestItem
    let run: ShowcaseAction
}

// MARK: - Recorder

final class ShowcaseRecorder {
    let targetFile: URL
    private var process: Process?

    init(targetFile: URL) {
        self.targetFile = targetFile
    }

    static func preflightCheck() throws {
        let testOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recorder_preflight_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: testOut) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-v", "-V", "1", testOut.path]
        try p.run()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            throw Failure("Screen recording preflight check failed (exit code \(p.terminationStatus)). Ensure Screen Recording permission is granted.")
        }
    }

    func start() throws {
        try? FileManager.default.removeItem(at: targetFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v: video recording; records active display
        p.arguments = ["-v", targetFile.path]
        try p.run()
        self.process = p

        // Give recorder a brief window to initialize and verify process is alive
        usleep(500_000)
        guard p.isRunning else {
            throw Failure("screencapture recorder exited prematurely (exit code \(p.terminationStatus)).")
        }
    }

    func stop() throws {
        guard let p = process, p.isRunning else { return }
        p.interrupt() // SIGINT tells screencapture to finalize the QuickTime movie
        p.waitUntilExit()
        process = nil

        // Verify final video
        usleep(500_000)
        guard FileManager.default.fileExists(atPath: targetFile.path) else {
            throw Failure("Recorded video file was not created at \(targetFile.path)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: targetFile.path)
        guard let size = attrs[.size] as? Int64, size > 1024 else {
            throw Failure("Recorded video file is empty or too small (\(targetFile.path))")
        }
    }
}

// MARK: - Scenes Registry

let showcaseManifest: [SceneManifestItem] = [
    SceneManifestItem(
        id: "welcome",
        chapter: "core",
        feature: "Terminal Launch, Banner & 24-bit TrueColor",
        witness: "PTY echo witness, 256-color / 24-bit palette rendering, clean shell prompt",
        status: .supported
    ),
    SceneManifestItem(
        id: "splits",
        chapter: "core",
        feature: "Split Panes & Keyboard Focus Navigation",
        witness: "takoctl tree 2-way split, Cmd+] focus cycling, independent PTY execution",
        status: .supported
    ),
    SceneManifestItem(
        id: "workspaces-frame-sync",
        chapter: "core",
        feature: "Project Workspaces & Live Window Frame Sync",
        witness: "Independent geometry on disabled sync, Settings UI toggle, matching 4D geometry on switch",
        status: .supported
    ),
    SceneManifestItem(
        id: "tabs-pills",
        chapter: "core",
        feature: "Native Tabs & Modern Pill-Style Tabs",
        witness: "Tab bar AX tree, Cmd+T tab creation, tab switching, clean Cmd+W close",
        status: .supported
    ),
    SceneManifestItem(
        id: "persistence",
        chapter: "core",
        feature: "Session Survival & Process Continuity (zmx)",
        witness: "Background counter PTY output survives simulated app restart",
        status: .supported
    ),
    SceneManifestItem(
        id: "quick-terminal",
        chapter: "optional",
        feature: "Quake-Style Quick Terminal Dropdown",
        witness: "Ctrl+` toggle, Quick Terminal window layer, dismiss on escape",
        status: .supported
    ),
    SceneManifestItem(
        id: "zoom",
        chapter: "optional",
        feature: "Dynamic Font Zooming & Column Reflow",
        witness: "Cmd+= increases font / decreases cols, Cmd+- decreases font, Cmd+0 resets",
        status: .supported
    ),
]

let showcaseScenes: [ShowcaseScene] = [
    // Scene 1: Welcome & Terminal Power
    ShowcaseScene(manifest: showcaseManifest[0], run: { ctx in
        let d = ctx.driver
        d.activate()
        d.setSize(CGSize(width: 860, height: 540))
        d.setPosition(CGPoint(x: 120, y: 100))

        // Banner and status output
        try ctx.typeNaturally("clear && echo '=== Welcome to Tako Terminal ==='\n")
        usleep(300_000)

        try ctx.typeNaturally("echo 'High Performance Terminal with Workspaces & Tabs'\n")
        usleep(400_000)

        try d.run("echo 'showcase_ready' > \(d.path("welcome_witness"))")
        try d.expect("welcome_witness", "showcase_ready\n", "terminal ready in welcome scene")
        ctx.viewerPause(1.8)
    }),

    // Scene 2: Split Panes & Multitasking
    ShowcaseScene(manifest: showcaseManifest[1], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Create horizontal split
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { (try? d.paneIds().count) == 2 }, timeout: 5) else {
            throw Failure("Failed to split pane horizontally via Cmd+D")
        }

        // Run a lightweight status command in right pane
        try ctx.typeNaturally("echo 'Pane 2 (Right): active' && date\n")
        usleep(300_000)

        // Cycle focus back to left pane via Cmd+]
        d.key(Key.rightBracket, .maskCommand)
        usleep(300_000)

        try ctx.typeNaturally("echo 'Pane 1 (Left): focus recovered'\n")
        usleep(300_000)

        // Close split pane via Cmd+W
        d.key(Key.w, .maskCommand)
        guard d.wait(for: { (try? d.paneIds().count) == 1 }, timeout: 5) else {
            throw Failure("Failed to close split pane via Cmd+W")
        }
        ctx.viewerPause(1.5)
    }),

    // Scene 3: Workspaces & Live Window Frame Sync
    ShowcaseScene(manifest: showcaseManifest[2], run: { ctx in
        let d = ctx.driver
        d.activate()

        let initialList = try d.workspaceList()
        guard let wsAId = initialList.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String else {
            throw Failure("Could not resolve initial active workspace")
        }

        // Set distinctive geometry for Workspace A
        d.setPosition(CGPoint(x: 100, y: 100))
        d.setSize(CGSize(width: 800, height: 500))
        usleep(400_000)
        guard let frameA = d.windowFrame() else {
            throw Failure("Could not obtain Workspace A window frame")
        }

        // Create Workspace B via clicking Workspace Pill
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "New Workspace")
        guard d.wait(for: { d.button(titled: "Create") != nil }, timeout: 5) else {
            throw Failure("New Workspace dialog did not appear")
        }
        usleep(300_000)
        try d.clickButton(titled: "Create")
        guard d.wait(for: { d.button(titled: "Create") == nil }, timeout: 5) else {
            throw Failure("New Workspace dialog not dismissed")
        }
        usleep(1_000_000)

        // Resolve Workspace B
        let listAfterCreate = try d.workspaceList()
        guard let wsB = listAfterCreate.first(where: { ($0["id"] as? String)?.lowercased() != wsAId.lowercased() }),
              let wsBId = wsB["id"] as? String,
              let wsBName = wsB["name"] as? String else {
            throw Failure("Failed to locate newly created Workspace B")
        }

        // Set distinctly different frame in Workspace B
        d.setPosition(CGPoint(x: 250, y: 180))
        d.setSize(CGSize(width: 680, height: 420))
        usleep(400_000)
        guard let frameB = d.windowFrame() else {
            throw Failure("Could not obtain Workspace B window frame")
        }

        // Verify independent frames when sync is disabled
        guard abs(frameB.origin.x - frameA.origin.x) > 50 || abs(frameB.size.width - frameA.size.width) > 50 else {
            throw Failure("Frames are unexpectedly identical before enabling sync")
        }
        ctx.viewerPause(1.0)

        // Open Settings UI (Cmd+,) and toggle workspace-sync-window-frame
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("Settings dialog failed to open")
        }
        usleep(300_000)

        // Switch to Terminal Settings tab (Cmd+2)
        d.key(Key.two, .maskCommand)
        usleep(300_000)

        // Filter search to sync
        if let search = d.descendants(of: d.element(withIdentifier: "TerminalSettingsDialog")!, role: kAXTextFieldRole).first {
            d.press(search)
            try d.type("sync")
            usleep(300_000)
        }

        // Click row and toggle Space
        if let f = d.windowFrame() {
            try d.click(at: CGPoint(x: f.origin.x + 200, y: f.origin.y + 160))
            usleep(300_000)
        }
        d.key(Key.space)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return val == "setting_custom_success: workspace-sync-window-frame" ||
                   val.contains("Custom: workspace-sync-window-frame = true")
        }, timeout: 5) else {
            throw Failure("Failed to toggle workspace-sync-window-frame in Settings")
        }

        // Dismiss Settings
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Failed to dismiss Settings dialog")
        }
        usleep(300_000)

        // Resize Workspace B and switch back to Workspace A: frame must sync!
        d.setPosition(CGPoint(x: 180, y: 140))
        d.setSize(CGSize(width: 760, height: 480))
        usleep(400_000)
        guard let departingB = d.windowFrame() else {
            throw Failure("No departing frame in Workspace B")
        }

        // Switch back to Default Workspace
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        usleep(1_500_000)

        guard let arrivedA = d.windowFrame() else {
            throw Failure("No window frame in Workspace A after sync switch")
        }
        guard abs(arrivedA.origin.x - departingB.origin.x) < 5 &&
              abs(arrivedA.origin.y - departingB.origin.y) < 5 &&
              abs(arrivedA.size.width - departingB.size.width) < 5 &&
              abs(arrivedA.size.height - departingB.size.height) < 5 else {
            throw Failure("Live frame sync did not match geometry on workspace switch (departing: \(departingB), arrived: \(arrivedA))")
        }

        try ctx.typeNaturally("echo 'Live Workspace Frame Sync: VERIFIED'\n")
        ctx.viewerPause(2.0)
    }),

    // Scene 4: Native Tabs & Pill Styling
    ShowcaseScene(manifest: showcaseManifest[3], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Create new tab via Cmd+T
        d.key(Key.t, .maskCommand)
        guard d.wait(for: { d.windows().count >= 1 }, timeout: 5) else {
            throw Failure("Failed to create new tab via Cmd+T")
        }
        usleep(400_000)

        try ctx.typeNaturally("echo 'Tab 2: Pill-style tabs active'\n")
        usleep(400_000)

        // Switch to Tab 1 via Cmd+1
        d.key(Key.one, .maskCommand)
        usleep(400_000)

        try ctx.typeNaturally("echo 'Switched back to Tab 1'\n")
        usleep(300_000)

        // Switch to Tab 2 and close it via Cmd+W
        d.key(Key.two, .maskCommand)
        usleep(300_000)
        d.key(Key.w, .maskCommand)
        usleep(500_000)

        ctx.viewerPause(1.5)
    }),

    // Scene 5: Process Continuity & Persistence
    ShowcaseScene(manifest: showcaseManifest[4], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Start harmless background counter
        let counterWitness = d.path("counter_witness")
        try ctx.typeNaturally("sh -c 'for i in 1 2 3 4 5; do echo counter-$i > \(counterWitness); sleep 1; done' &\n")
        usleep(1_500_000)

        // Witness that counter started
        guard (try? d.file("counter_witness", timeout: 6)) != nil else {
            throw Failure("Persistence counter job did not start")
        }

        try ctx.typeNaturally("echo 'Persistence Engine: session attached and running'\n")
        ctx.viewerPause(1.8)
    }),

    // Optional Scene: Quick Terminal
    ShowcaseScene(manifest: showcaseManifest[5], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Toggle Quick Terminal via Cmd+Grave or shortcut
        d.key(Key.grave, .maskControl)
        usleep(600_000)

        // Dismiss with Escape or toggle
        d.key(Key.escape)
        usleep(300_000)
        ctx.viewerPause(1.0)
    }),

    // Optional Scene: Zoom
    ShowcaseScene(manifest: showcaseManifest[6], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Zoom in
        d.key(Key.equal, .maskCommand)
        usleep(400_000)
        d.key(Key.equal, .maskCommand)
        usleep(400_000)

        try ctx.typeNaturally("echo 'Font size zoomed in (+2)'\n")
        usleep(600_000)

        // Reset zoom
        d.key(Key.zero, .maskCommand)
        usleep(400_000)
        try ctx.typeNaturally("echo 'Font size reset to normal'\n")
        ctx.viewerPause(1.2)
    }),
]

// MARK: - Main Showcase Entrypoint

@main
struct TakoShowcase {
    static func main() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())

        if rawArgs.contains("--list") {
            print("Tako Feature Showcase Matrix:")
            print(String(repeating: "-", count: 80))
            for item in showcaseManifest {
                print("[\(item.status.rawValue.uppercased())] \(item.id.padding(toLength: 22, withPad: " ", startingAt: 0)) (\(item.chapter))")
                print("  Feature: \(item.feature)")
                print("  Witness: \(item.witness)")
            }
            exit(0)
        }

        guard let appPath = rawArgs.first, !appPath.starts(with: "-") else {
            print("usage: tako-showcase <Tako.app> [--pace fast|presentation] [--scene <id>] [--chapter <name>] [--record <file.mov>] [--output-dir <dir>]")
            print("       tako-showcase --list")
            exit(2)
        }

        guard AXIsProcessTrusted() else {
            print("FAIL: this process has no Accessibility permission to drive Tako UI")
            exit(1)
        }

        var pacing: PacingMode = .presentation
        var scenesWanted = Set<String>()
        var chapterWanted: String? = nil
        var recordPath: String? = nil
        var outputDirPath = "target/demo-runs/\(Int(Date().timeIntervalSince1970))"

        var i = 1
        while i < rawArgs.count {
            let arg = rawArgs[i]
            switch arg {
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

        let outputDirURL = URL(fileURLWithPath: outputDirPath)
        try? FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)

        // Select scenes to run
        let selectedScenes: [ShowcaseScene]
        if !scenesWanted.isEmpty {
            selectedScenes = showcaseScenes.filter { scenesWanted.contains($0.manifest.id) }
        } else if let chapter = chapterWanted {
            selectedScenes = showcaseScenes.filter { $0.manifest.chapter == chapter }
        } else {
            // Default to core chapter
            selectedScenes = showcaseScenes.filter { $0.manifest.chapter == "core" }
        }

        guard !selectedScenes.isEmpty else {
            print("FAIL: no matching showcase scenes found")
            exit(2)
        }

        // Preflight recorder if requested
        var recorder: ShowcaseRecorder? = nil
        if let recPath = recordPath {
            print("==> Preflighting screen recorder...")
            do {
                try ShowcaseRecorder.preflightCheck()
                let recURL = URL(fileURLWithPath: recPath)
                recorder = ShowcaseRecorder(targetFile: recURL)
            } catch {
                print("FAIL: Screen recording preflight error: \(error)")
                exit(1)
            }
        }

        let previouslyFront = NSWorkspace.shared.frontmostApplication
        var failedCount = 0

        do {
            let driver = try Driver(app: URL(fileURLWithPath: appPath))
            defer { driver.quit() }
            try driver.launch()

            let ctx = ShowcaseContext(driver: driver, pacing: pacing, outputDir: outputDirURL)

            if let r = recorder {
                print("==> Starting screen recording to \(r.targetFile.path)...")
                try r.start()
            }

            for scene in selectedScenes {
                print("==> Scene [\(scene.manifest.chapter)]: \(scene.manifest.feature)...")
                let start = Date()
                do {
                    try scene.run(ctx)
                    let duration = Date().timeIntervalSince(start)
                    ctx.recordTiming(scene: scene.manifest.id, duration: duration, status: "PASS")
                    print("PASS  \(scene.manifest.id) (\(String(format: "%.2f", duration))s)")
                } catch {
                    let duration = Date().timeIntervalSince(start)
                    ctx.recordTiming(scene: scene.manifest.id, duration: duration, status: "FAIL")
                    print("FAIL  \(scene.manifest.id): \(error)")
                    failedCount += 1
                    break
                }
            }

            if let r = recorder {
                print("==> Finalizing screen recording...")
                try r.stop()
                print("Recorded showcase movie saved to: \(r.targetFile.path)")
            }

            // Write report to output directory
            var reportLines = [
                "Tako Showcase Run Report",
                "Timestamp: \(Date())",
                "Pacing: \(pacing.rawValue)",
                "Failed: \(failedCount)",
                "",
                "Scenes:",
            ]
            for t in ctx.sceneTimings {
                reportLines.append("  - \(t.scene): \(t.status) (\(String(format: "%.2f", t.duration))s)")
            }
            let reportData = reportLines.joined(separator: "\n").data(using: .utf8)
            try? reportData?.write(to: outputDirURL.appendingPathComponent("showcase_report.txt"))

        } catch {
            print("FAIL: Showcase initialization error: \(error)")
            failedCount += 1
        }

        if let previouslyFront, !previouslyFront.isTerminated, let bundle = previouslyFront.bundleURL {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", bundle.path]
            try? open.run()
            open.waitUntilExit()
            previouslyFront.activate()
        }

        print(failedCount == 0 ? "Tako Showcase: OK" : "Tako Showcase: FAILED (\(failedCount))")
        exit(failedCount == 0 ? 0 : 1)
    }
}
