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

// MARK: - Extra & Advanced Scenes Implementations

let extraShowcaseScenes: [ShowcaseScene] = [
    // Scene 4: Native Tabs & Pill Styling
    ShowcaseScene(manifest: showcaseManifest[3], run: { ctx in
        let d = ctx.driver
        d.activate()

        let initialWinCount = d.windows().count
        guard initialWinCount >= 1 else {
            throw Failure("No open windows at start of tabs scene")
        }

        // Open new tab via Cmd+T
        d.key(Key.t, .maskCommand)
        usleep(800_000)

        // Type in Tab 2 and verify witness
        let tab2Witness = d.path("tab2_witness")
        try ctx.typeNaturally("echo 'tab2_ok' > \(tab2Witness)\n")
        try d.expect("tab2_witness", "tab2_ok\n", "Tab 2 typing witness")

        // Switch to Tab 1 via Cmd+1
        d.key(Key.one, .maskCommand)
        usleep(500_000)

        // Type in Tab 1 and verify witness
        let tab1Witness = d.path("tab1_witness")
        try ctx.typeNaturally("echo 'tab1_ok' > \(tab1Witness)\n")
        try d.expect("tab1_witness", "tab1_ok\n", "Tab 1 typing witness")

        // Switch back to Tab 2 and close it via Cmd+W
        d.key(Key.two, .maskCommand)
        usleep(400_000)
        d.key(Key.w, .maskCommand)
        usleep(250_000)
        if let closeBtn = d.button(titled: "Close") {
            d.press(closeBtn)
            usleep(250_000)
        }
        usleep(400_000)

        // Verify Tab 1 resumed and responsive
        let tabResumeWitness = d.path("tab_resumed_witness")
        try ctx.typeNaturally("echo 'tab_resumed_ok' > \(tabResumeWitness)\n")
        try d.expect("tab_resumed_witness", "tab_resumed_ok\n", "Tab 1 resumed after closing Tab 2")

        ctx.viewerPause(1.5)
    }),

    // Scene 5: Process Continuity & Session Persistence (zmx)
    ShowcaseScene(manifest: showcaseManifest[4], run: { ctx in
        let d = ctx.driver
        d.activate()

        let zsPath = d.path("zs")
        let pid1Path = d.path("pid1")
        try d.run("sh -c 'echo $PPID' > \(pid1Path); env | grep -c ZMX_SESSION > \(zsPath)")
        guard (try? d.file("zs").trimmingCharacters(in: .whitespacesAndNewlines)) == "1" else {
            throw Failure("Terminal shell is not inside a persistent zmx session")
        }
        guard let pid1Str = try? d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines),
              let pid1 = Int(pid1Str), pid1 > 0 else {
            throw Failure("Could not resolve shell PPID before persistence restart")
        }

        let counterWitness = d.path("persistence_counter_witness")
        // Start background counting loop in persistent shell
        try ctx.typeNaturally("sh -c 'n=1; while [ $n -le 30 ]; do echo $n > \(counterWitness); sleep 1; n=$((n+1)); done' &\n")
        usleep(2_500_000)

        guard let firstStr = try? d.file("persistence_counter_witness", timeout: 6),
              let val1 = Int(firstStr.trimmingCharacters(in: .whitespacesAndNewlines)), val1 >= 2 else {
            throw Failure("Background counter did not reach initial threshold (>= 2)")
        }

        let appPidBefore = d.pid

        // Quit app normally
        try d.quitNormally()
        guard !d.isRunning else {
            throw Failure("App was still running after quitNormally")
        }

        // Wait 2.0s while background counter continues ticking in persistent zmx session
        usleep(2_000_000)

        // Relaunch app with session-persistence = true
        let persistConfig = "window-save-state = always\nsession-persistence = true\nremote-control = on\nconfirm-close-surface = false\n"
        try d.launch(config: persistConfig)
        guard d.isRunning && d.pid != appPidBefore else {
            throw Failure("App did not relaunch with a fresh process")
        }

        // Verify same shell survived across app restart
        let pid2Path = d.path("pid2")
        try d.run("sh -c 'echo $PPID' > \(pid2Path)")
        let pid2Read = try? d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid2Str = pid2Read,
              let pid2 = Int(pid2Str), pid2 == pid1 else {
            let actual = pid2Read ?? "nil"
            throw Failure("Shell did not persist across app restart: initial PPID \(pid1), after restart PPID \(actual)")
        }

        // Read counter: value must have advanced during restart!
        guard let secondStr = try? d.file("persistence_counter_witness", timeout: 6),
              let val2 = Int(secondStr.trimmingCharacters(in: .whitespacesAndNewlines)), val2 > val1 else {
            throw Failure("Session counter did not continue across app restart (val1: \(val1))")
        }

        // Verify terminal input delivery in reattached session
        let reattachWitness = d.path("reattach_witness")
        try ctx.typeNaturally("echo 'reattach_verified' > \(reattachWitness)\n")
        try d.expect("reattach_witness", "reattach_verified\n", "terminal input after persistence reattach")

        // Cleanly exit persistent shell so session is closed
        try d.run("exit")

        ctx.viewerPause(1.8)
    }),

    // Optional Scene: Quick Terminal
    ShowcaseScene(manifest: showcaseManifest[5], run: { ctx in
        let d = ctx.driver
        d.activate()

        // Toggle Quick Terminal via Cmd+Shift+`
        d.key(Key.grave, [.maskCommand, .maskShift])
        usleep(1_200_000)

        let qTreePath = d.path("qtree")
        let qSelfPath = d.path("qself")
        try d.run("takoctl tree --json > \(qTreePath); echo $TAKO_SURFACE_ID > \(qSelfPath)")
        let tree = (try? d.file("qtree")) ?? ""
        let me = (try? d.file("qself").trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        // Dismiss Quick Terminal via Cmd+Shift+`
        d.key(Key.grave, [.maskCommand, .maskShift])
        usleep(600_000)

        guard tree.contains("\"ok\":true"), tree.contains("quick-terminal"), !me.isEmpty, tree.contains("\"id\":\"\(me)\"") else {
            throw Failure("Quick Terminal was not discoverable in tree with active surface id: \(tree.prefix(300))")
        }
        ctx.viewerPause(1.0)
    }),

    // Optional Scene: Zoom
    ShowcaseScene(manifest: showcaseManifest[6], run: { ctx in
        let d = ctx.driver
        d.activate()
        d.setSize(CGSize(width: 860, height: 540))
        usleep(400_000)

        let cols1Path = d.path("cols1")
        try d.run("tput cols > \(cols1Path)")
        let before = Int((try? d.file("cols1").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? 0
        guard before > 0 else {
            throw Failure("Could not determine initial terminal columns")
        }

        // Zoom in twice via Cmd+=
        d.key(Key.equal, .maskCommand)
        usleep(300_000)
        d.key(Key.equal, .maskCommand)
        usleep(600_000)

        let cols2Path = d.path("cols2")
        try d.run("tput cols > \(cols2Path)")
        let bigger = Int((try? d.file("cols2").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? 0
        guard bigger < before else {
            throw Failure("Zooming in did not decrease columns: before \(before), after \(bigger)")
        }

        // Reset zoom via Cmd+0
        d.key(Key.zero, .maskCommand)
        usleep(600_000)

        let cols3Path = d.path("cols3")
        try d.run("tput cols > \(cols3Path)")
        let reset = Int((try? d.file("cols3").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? 0
        guard reset == before else {
            throw Failure("Zoom reset did not return to initial columns: before \(before), reset \(reset)")
        }
        ctx.viewerPause(1.2)
    }),
]

let showcaseScenes: [ShowcaseScene] = coreShowcaseScenes + extraShowcaseScenes
