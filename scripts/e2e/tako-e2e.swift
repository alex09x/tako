/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Drives a built Tako.app the way a person does and checks what the program
// inside it actually received.
//
// Key presses are real keyboard events posted to the app's process: they go
// through the window server, AppKit's event routing, the menus' key
// equivalents and the text input system, exactly as typing does. Windows,
// tabs and alerts are read and pressed through the accessibility tree. What
// reached the shell is checked by having the shell write it to a file --
// the one witness that cannot be fooled by what the screen looks like.
//
// Events are posted to Tako's pid, never to whatever app is in front, so a
// run cannot type into another app's windows. Tako is launched the ordinary
// way, which makes it the active app -- menu key equivalents act on the key
// window, and an app in the background has none -- and the app that was in
// front is given the focus back when the run ends.
//
//   swiftc -O -o tako-e2e scripts/e2e/tako-e2e.swift
//   ./tako-e2e target/macapp/Tako.app [scenario ...]
//
// Needs Accessibility permission for the process running it, and a US-style
// keyboard layout (key codes are typed, and the layout turns them into
// characters, as it would for a person).

import AppKit
import ApplicationServices
import Foundation


// MARK: - Scenarios

typealias Scenario = (name: String, why: String, body: (Driver) throws -> Void)

let scenarios: [Scenario] = [
    ("restore", "a relaunch shows the tab's old screen and starts its shell where it was", { d in
        d.quit()
        // Every scenario ends with a kill, which the layout journal rightly
        // treats as a crash: start from nothing an earlier scenario left.
        forgetLayout(d)
        try d.launch(config: "")
        // A marker and a directory of this run only, so a screen restored
        // from an earlier run cannot pass for this one. The output, not the
        // command line, holds the marker; any shell's printf makes it.
        let id = d.work.lastPathComponent
        let marker = "restore-\(id)"
        let dir = d.path("cwd")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Right after launch the shell can still be starting and drop what is
        // typed; the command is harmless to repeat, so repeat it until it shows.
        var shown = false
        for _ in 0..<3 where !shown {
            try d.run("cd \(dir); printf 'restore-%s\\n' \(id)")
            shown = d.wait(for: { d.screenText().contains(marker) }, timeout: 5)
        }
        guard shown else {
            throw Failure("the marker never showed: [\(d.screenText().suffix(300))]")
        }
        try d.quitNormally()
        try d.launch(config: "")
        let screen = d.screenText()
        guard screen.contains(marker), !screen.contains("restored from")
        else { throw Failure("this run's screen was not restored as it was: [\(screen)]") }
        try d.run("pwd -P > \(d.path("pwd"))")
        // pwd -P resolves /tmp to /private/tmp; Foundation's resolving keeps
        // /tmp, so ask the C library.
        guard let real = realpath(dir, nil) else { throw Failure("no real path for \(dir)") }
        let resolved = String(cString: real)
        free(real)
        try d.expect("pwd", resolved + "\n", "the restored shell's directory")
    }),
    ("typing", "what is typed reaches the shell, two spaces as two spaces", { d in
        try d.run("printf '%s' 'a  b' > \(d.path("typed"))")
        try d.expect("typed", "a  b", "typed text")
    }),
    ("option-space", "Option+Space types a plain space, not a no-break space", { d in
        try d.type("printf '%s' 'x")
        d.key(Key.space, .maskAlternate)
        try d.run("y' > \(d.path("optspace"))")
        try d.expect("optspace", "x y", "Option+Space")
    }),
    ("editing", "arrow keys and backspace edit the line the shell holds", { d in
        try d.type("echo ac > \(d.path("arrows"))")
        // Back over " > <path>" and the "c", then insert.
        for _ in 0..<(" > \(d.path("arrows"))".count + 1) { d.key(Key.left) }
        try d.type("b")
        d.key(Key.returnKey)
        try d.expect("arrows", "abc\n", "left arrow then typing")

        try d.type("echo abx")
        d.key(Key.delete)
        try d.run("c > \(d.path("backspace"))")
        try d.expect("backspace", "abc\n", "backspace")
    }),
    ("control-keys", "ctrl+u clears the line and ctrl+c stops a running command", { d in
        try d.type("echo wrong")
        d.key(Key.u, .maskControl)
        try d.run("echo right > \(d.path("ctrlu"))")
        try d.expect("ctrlu", "right\n", "ctrl+u")

        try d.run("sleep 30; echo late > \(d.path("late"))")
        usleep(800_000)
        d.key(Key.c, .maskControl)
        try d.run("echo after > \(d.path("after"))")
        _ = try d.file("after", timeout: 5)
        guard !FileManager.default.fileExists(atPath: d.path("late")) else {
            throw Failure("ctrl+c did not stop the command")
        }
    }),
    ("find-all", "cmd+shift+f finds output in another tab and shows it there, selected", { d in
        let id = d.work.lastPathComponent
        try d.run("tty > \(d.path("tty1")); printf 'found-%s\\n' \(id)")
        let first = try d.file("tty1")
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty2")); printf 'other output\\n'")
        guard try d.file("tty2") != first else { throw Failure("cmd+t did not open a second terminal") }

        d.key(Key.f, [.maskCommand, .maskShift])
        usleep(600_000)
        try d.type("found-\(id)")
        usleep(800_000)
        d.key(Key.returnKey)
        usleep(1_000_000)

        guard d.wait(for: { d.selectedText() == "found-\(id)" }, timeout: 5) else {
            throw Failure("selection after Return is [\(d.selectedText())]")
        }
        try d.run("tty > \(d.path("tty3"))")
        guard try d.file("tty3") == first else {
            throw Failure("Return did not bring the keyboard to the tab with the match")
        }
    }),
    ("find-commands", "find in all tabs groups matches under the shell command that printed them", { d in
        // The bundled zsh integration, whatever the login shell is: it marks
        // the prompt, the command line, the output and the exit status.
        let id = d.work.lastPathComponent
        let marker = "grp-\(id)"
        try d.run("exec env ZDOTDIR=$TAKO_RESOURCES_DIR/shell-integration/zsh zsh -i")
        usleep(2_000_000)
        try d.run("cd \(d.work.path)")
        // The id is passed apart from the format, so no command line holds
        // the marker: only output does.
        try d.run("printf 'grp-%s ok\\n' \(id)")
        try d.run("printf 'grp-%s one\\ngrp-%s two\\n' \(id) \(id); false")
        guard d.wait(for: { d.screenText().contains("\(marker) two") }, timeout: 5) else {
            throw Failure("the commands did not run: [\(d.screenText().suffix(300))]")
        }

        d.key(Key.f, [.maskCommand, .maskShift])
        usleep(600_000)
        d.key(Key.a, .maskCommand)
        try d.type(marker)
        guard d.wait(for: { d.staticTexts().filter { $0.contains(marker) }.count == 3 }, timeout: 5) else {
            throw Failure("expected three matches: \(d.staticTexts())")
        }
        let texts = d.staticTexts()
        let failing = "$ printf 'grp-%s one\\ngrp-%s two\\n' \(id) \(id); false"
        let passing = "$ printf 'grp-%s ok\\n' \(id)"
        // One heading per command, however many of its lines matched.
        guard texts.filter({ $0 == failing }).count == 1, texts.filter({ $0 == passing }).count == 1 else {
            throw Failure("headings: \(texts)")
        }
        let details = texts.filter { $0.contains("exit") }
        let dir = d.work.resolvingSymlinksInPath().path
        guard details.count == 2,
              details.contains(where: { $0.hasPrefix("✗ exit 1") }),
              details.contains(where: { $0.hasPrefix("✓ exit 0") }),
              details.allSatisfy({ $0.contains(dir) || $0.contains(d.work.path) }),
              details.allSatisfy({ $0.contains("started ") }) else {
            throw Failure("details: \(details)")
        }
        // Newest first: the failing command's lines come before the other's.
        guard let fi = texts.firstIndex(of: failing), let pi = texts.firstIndex(of: passing), fi < pi else {
            throw Failure("order: \(texts)")
        }

        d.key(Key.returnKey)
        guard d.wait(for: { d.selectedText() == marker }, timeout: 5) else {
            throw Failure("selection after Return is [\(d.selectedText())]")
        }
        try d.run("exit")
    }),
    ("ctl-tree", "takoctl inside a pane sees that pane, and refuses what it must", { d in
        d.quit()
        try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = local\n")
        // On PATH through the shell integration's `path` feature.
        try d.run("takoctl tree --json > \(d.path("tree")); echo $TAKO_SURFACE_ID > \(d.path("self")); cd \(d.work.path)")
        let tree = try d.file("tree")
        let me = try d.file("self").trimmingCharacters(in: .whitespacesAndNewlines)
        guard me.count == 36, tree.contains("\"id\":\"\(me)\""), tree.contains("\"ok\":true") else {
            throw Failure("tree does not list this pane \(me): \(tree.prefix(400))")
        }
        // Without the pane context, the default setting refuses.
        try d.run("sh -c 'env -u TAKO_SURFACE_ID takoctl version 2> \(d.path("err")); echo $? > \(d.path("rc"))'")
        guard try d.file("rc").trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              try d.file("err").contains("disabled") else {
            throw Failure("a request from outside a pane was not refused: \(try d.file("err"))")
        }
        try d.run("takoctl version > \(d.path("ver"))")
        guard try d.file("ver").contains("protocol 1") else { throw Failure("version: \(try d.file("ver"))") }
    }),
    ("ctl-quick", "takoctl works from the Quick Terminal, which tree lists", { d in
        d.key(Key.grave, [.maskCommand, .maskShift])
        usleep(1_500_000)
        try d.run("takoctl tree --json > \(d.path("qtree")); echo $TAKO_SURFACE_ID > \(d.path("qself"))")
        let tree = try d.file("qtree")
        let me = try d.file("qself").trimmingCharacters(in: .whitespacesAndNewlines)
        d.key(Key.grave, [.maskCommand, .maskShift])
        guard tree.contains("\"ok\":true"), tree.contains("quick-terminal"), tree.contains("\"id\":\"\(me)\"") else {
            throw Failure("from the Quick Terminal \(me): \(tree.prefix(500))")
        }
    }),
    ("ctl-layout", "takoctl splits, types, reads, retitles, opens a tab behind and closes with the user's answer", { d in
        let id = d.work.lastPathComponent
        let out = d.work.path
        // Each phase is a small sh script run in the pane, so fish and zsh
        // alike run it; results go to files the driver reads.
        func script(_ name: String, _ body: String) throws {
            try body.write(toFile: d.path(name), atomically: true, encoding: .utf8)
        }
        try script("setup.sh", """
        me=$TAKO_SURFACE_ID
        b=$(takoctl split right) || exit 1
        echo "$b" > \(out)/b
        takoctl type "echo split-\(id)" --target "$b"
        sleep 0.5
        takoctl text --target "$b" --lines 3 > \(out)/typed
        takoctl key enter --target "$b"
        sleep 1
        takoctl text --target "$b" --lines 5 > \(out)/ran
        takoctl title "ctl-\(id)" --target "$b" && echo ok > \(out)/titled
        takoctl tree --json > \(out)/before
        takoctl tab-new --no-select --target "$me" > \(out)/f
        sleep 1
        takoctl tree --json > \(out)/after
        takoctl send "sleep 300" --target "$b"
        takoctl focus --target "$me"
        sleep 0.5
        takoctl tree --json > \(out)/refocused
        echo "$me" > \(out)/me
        echo done > \(out)/setup
        """)
        try d.run("sh \(d.path("setup.sh"))")
        _ = try d.file("setup", timeout: 20)
        let b = try d.file("b").trimmingCharacters(in: .whitespacesAndNewlines)
        guard b.count == 36 else { throw Failure("split gave no pane id: \(b)") }
        // type: the text is on the line, not yet run; key enter: it ran.
        let typed = try d.file("typed"), ran = try d.file("ran")
        guard typed.contains("echo split-\(id)"), !typed.contains("\nsplit-\(id)"),
              ran.contains("\nsplit-\(id)") else {
            throw Failure("type/key/text: typed=\(typed) ran=\(ran)")
        }
        guard try d.file("titled").contains("ok") else { throw Failure("title failed") }
        // tab-new --no-select: a new pane, and the focused pane did not change.
        let before = try d.file("before"), after = try d.file("after")
        let f = try d.file("f").trimmingCharacters(in: .whitespacesAndNewlines)
        guard f.count == 36, after.contains(f), !before.contains(f) else {
            throw Failure("tab-new: \(f) not in tree")
        }
        // The pane object whose "focused" is true: parsed, not pattern-matched.
        func focusedID(_ json: String) -> String? {
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return nil }
            for window in windows {
                for tab in window["tabs"] as? [[String: Any]] ?? [] {
                    for pane in tab["panes"] as? [[String: Any]] ?? [] where pane["focused"] as? Bool == true {
                        return pane["id"] as? String
                    }
                }
            }
            return nil
        }
        guard let fb = focusedID(before), focusedID(after) == fb else {
            throw Failure("--no-select moved the focus: \(focusedID(before) ?? "-") -> \(focusedID(after) ?? "-")")
        }
        // focus: the keyboard is back in this pane.
        let me = try d.file("me").trimmingCharacters(in: .whitespacesAndNewlines)
        guard focusedID(try d.file("refocused")) == me else {
            throw Failure("focus did not return to \(me); focused \(focusedID(try d.file("refocused")) ?? "-"), b \(b), f \(f): \(try d.file("refocused"))")
        }
        // close a pane with a running process: the question; Escape = cancelled.
        try script("close1.sh", "takoctl close --target \(b) > \(out)/close1; echo $? > \(out)/close1.rc")
        try d.run("sh \(d.path("close1.sh")) &")
        usleep(1_500_000)
        d.key(Key.escape)
        _ = try d.file("close1.rc", timeout: 10)   // written after the answer
        guard try d.file("close1").contains("cancelled") else {
            throw Failure("Cancel was not reported: \(try d.file("close1"))")
        }
        // Again, and Return = closed.
        try script("close2.sh", "takoctl close --target \(b) > \(out)/close2; echo $? > \(out)/close2.rc")
        try d.run("sh \(d.path("close2.sh")) &")
        usleep(1_500_000)
        d.key(Key.returnKey)
        _ = try d.file("close2.rc", timeout: 10)   // written after the answer
        guard try d.file("close2").contains("closed") else {
            throw Failure("closing was not reported: \(try d.file("close2"))")
        }
        // The pane is gone: notFound, exit 1, nothing else closed.
        try d.run("sh -c 'takoctl close --target \(b) 2> \(out)/close3; echo $? > \(out)/close3.rc'")
        guard try d.file("close3.rc").trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              try d.file("close3").contains("notFound") else {
            throw Failure("closing a gone pane: \(try d.file("close3"))")
        }
    }),
    ("ctl-close-wait", "a close nobody answers is withdrawn and reported cancelled; a late Return closes nothing", { d in
        d.quit()
        d.environment = ["TAKO_CLOSE_WAIT": "3"]
        defer { d.environment = [:] }
        try d.launch()
        let out = d.work.path
        try """
        b=$(takoctl split right) || exit 1
        echo "$b" > \(out)/b
        takoctl send "sleep 300" --target "$b"
        sleep 1
        takoctl close --target "$b" > \(out)/c
        takoctl focus --target "$TAKO_SURFACE_ID"
        echo $? > \(out)/c.rc
        """.write(toFile: d.path("cw.sh"), atomically: true, encoding: .utf8)
        try d.run("sh \(d.path("cw.sh"))")
        _ = try d.file("c.rc", timeout: 15)
        guard try d.file("c").contains("cancelled") else { throw Failure("answer: \(try d.file("c"))") }
        // The question is gone: Return now must not close the pane.
        d.key(Key.returnKey)
        usleep(1_000_000)
        let b = try d.file("b").trimmingCharacters(in: .whitespacesAndNewlines)
        try d.run("takoctl tree --json > \(d.path("tree"))")
        guard try d.file("tree").contains(b) else { throw Failure("a late Return closed \(b)") }
    }),
    ("crash-layout", "tabs and splits made shortly before a crash come back after it", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        d.quit()
        forgetLayout(d)
        let config = "window-save-state = always\n"
        try d.launch(config: config)
        let out = d.work.path
        try """
        b=$(takoctl split right) || exit 1
        f=$(takoctl tab-new --no-select) || exit 1
        takoctl tree --json > \(out)/before
        echo done > \(out)/made
        """.write(toFile: d.path("make.sh"), atomically: true, encoding: .utf8)
        try d.run("sh \(d.path("make.sh"))")
        _ = try d.file("made", timeout: 15)
        func count(_ json: String) -> (tabs: Int, panes: Int) {
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return (0, 0) }
            let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            return (tabs.count, tabs.reduce(0) { $0 + (($1["panes"] as? [Any])?.count ?? 0) })
        }
        let before = count(try d.file("before"))
        guard before.tabs >= 2, before.panes >= 3 else { throw Failure("layout not made: \(before)") }
        usleep(UInt32(ProcessInfo.processInfo.environment["TAKO_E2E_CRASH_WAIT"].flatMap(Double.init).map { $0 * 1_000_000 } ?? 3_000_000))
        d.quit()                          // SIGKILL: a crash, nothing saved on the way out
        usleep(1_000_000)
        try d.launch(config: config)
        usleep(1_500_000)
        try d.run("takoctl tree --json > \(d.path("after"))")
        let after = count(try d.file("after"))
        guard after.tabs >= before.tabs, after.panes >= before.panes else {
            throw Failure("after the crash: \(after.tabs) tabs, \(after.panes) panes; before: \(before.tabs), \(before.panes)")
        }
    }),
    ("crash-again", "a crash while restoring after a crash still restores the layout", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        d.quit()
        try d.launch(config: "window-save-state = always\n")
        d.quit()                          // a second crash, straight after the restore began
        usleep(500_000)
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs >= 2, after.panes >= 3 else { throw Failure("after two crashes: \(after)") }
    }),
    ("crash-corrupt", "a damaged journal restores nothing from itself and duplicates nothing", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        d.quit()
        let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
        let layout = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle).appendingPathComponent("layout")
        // Every journal generation damaged: whichever launch.json names.
        for name in try FileManager.default.contentsOfDirectory(atPath: layout.path) where name.hasPrefix("journal-") {
            try Data("{\"version\":1,\"generation\":9,\"windows\":[{\"tabs\":".utf8)
                .write(to: layout.appendingPathComponent(name))
        }
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        // One fresh window: none of the journal's, and no second copy from AppKit.
        guard after.windows == 1, after.tabs == 1, after.panes == 1 else { throw Failure("after a damaged journal: \(after)") }
    }),
    ("quit-layout", "a normal quit restores the layout once, without duplicates", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        try d.quitNormally()
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs == 2, after.panes == 3 else { throw Failure("after a normal quit: \(after)") }
    }),
    ("upgrade-crash", "a layout AppKit saved survives a crash right after the first launch that keeps a journal", { d in
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        try d.quitNormally()
        // As before the journal existed: only AppKit's saved state.
        let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Application Support/\(bundle)/layout"))
        try d.launch(config: "window-save-state = always\n")
        d.quit()                          // straight after AppKit restored, before any timer
        usleep(500_000)
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs == 2, after.panes == 3 else { throw Failure("after the upgrade crash: \(after)") }
    }),
    ("persist-live", "with session-persistence a relaunch reattaches to the same shell", { d in
        // Needs an app built with its session runtime (TAKO_WITH_ZMX=1).
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1")); env | grep -c ZMX_SESSION > \(d.path("zs"))")
        let first = try d.file("pid1")
        guard try d.file("zs").trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw Failure("the shell is not inside a session")
        }
        try d.quitNormally()
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        let second = try d.file("pid2")
        // End the session so nothing is left running.
        try d.run("exit")
        guard first == second else { throw Failure("a new shell after relaunch: \(first) then \(second)") }
    }),
    ("persist-gone", "a session that ended while Tako was closed comes back as its saved screen and a new shell", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        let id = d.work.lastPathComponent
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1")); printf 'gone-%s\\n' \(id)")
        guard let first = try? d.file("pid1") else { throw Failure("no shell: [\(d.screenText().suffix(400))]") }
        guard d.wait(for: { d.screenText().contains("gone-\(id)") }, timeout: 5) else { throw Failure("no marker") }
        // A real save before quitting, so the snapshot holds the marker.
        try d.quitNormally()
        // End the shell behind Tako's back, the way a reboot would.
        let shell = Int32(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard shell > 0, kill(shell, SIGKILL) == 0 else { throw Failure("could not end the shell \(first)") }
        usleep(1_000_000)
        try d.launch(config: config)
        guard d.wait(for: { d.screenText().contains("gone-\(id)") }, timeout: 10) else {
            throw Failure("the saved screen did not come back: [\(d.screenText().suffix(300))]")
        }
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        let second = try d.file("pid2")
        try d.run("exit")
        guard first != second else { throw Failure("the same shell after it was killed?") }
        guard !d.screenText().contains("[Tako]") else { throw Failure("an error was shown: \(d.screenText().suffix(300))") }
    }),
    ("persist-close", "closing a persistent tab ends its session once undo has expired", { d in
        d.quit()
        let config = "session-persistence = true\nconfirm-close-surface = false\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let shell = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              shell != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        // Undo keeps a closed tab for 5 s; then it is released and its
        // session ends with it.
        guard d.wait(for: { kill(shell, 0) != 0 }, timeout: 15) else {
            throw Failure("the shell \(shell) of the closed tab is still running")
        }
        guard kill(kept, 0) == 0 else { throw Failure("the open tab's session was killed") }
    }),
    ("persist-close-asks", "closing a persistent tab asks first, and Cancel keeps its session", { d in
        d.quit()
        try d.launch(config: "session-persistence = true\n")
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let shell = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              shell != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+w on persistent tab did not show confirmation dialog with Cancel button")
        }
        d.press(cancel)
        guard d.wait(for: { d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("confirmation dialog remained open after Cancel")
        }
        usleep(7_000_000)          // past the undo window
        guard kill(shell, 0) == 0 else { throw Failure("closing ended the session without asking") }
        try d.run("echo still > \(d.path("still"))")
        _ = try d.file("still")
        try d.run("exit")
    }),
    ("persist-close-quit", "a tab closed just before quitting still has its session ended", { d in
        d.quit()
        let config = "session-persistence = true\nconfirm-close-surface = false\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        // A second tab, closed (it has the keyboard), then quit at once --
        // well inside its undo window.
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let closed = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              closed != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        usleep(500_000)
        try d.quitNormally()
        guard d.wait(for: { kill(closed, 0) != 0 }, timeout: 8) else {
            throw Failure("the closed tab's shell outlived the quit")
        }
        guard kill(kept, 0) == 0 else { throw Failure("the open tab's session did not survive the quit") }
    }),
    ("persist-second-owner", "a second copy of Tako restoring the same session is refused and starts nothing", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid"))")
        guard let shell = Int32(try d.file("pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        // Saved with its session, then reattached: this copy owns it.
        try d.quitNormally()
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines) == String(shell) else {
            throw Failure("the first copy did not reattach")
        }
        // A second copy restores the same window, so the same session.
        let other = try d.launchAnother(config: config)
        defer { kill(other, SIGKILL) }
        guard d.wait(for: { d.screenTexts(ofPid: other).contains { $0.contains("open in another copy of Tako") } },
                     timeout: 15) else {
            throw Failure("the second copy said nothing about the session: \(d.screenTexts(ofPid: other).map { $0.suffix(200) })")
        }
        // It started nothing: the session still has its one shell, and the
        // first copy still drives it.
        try d.run("sh -c 'echo $PPID' > \(d.path("pid3"))")
        guard try d.file("pid3").trimmingCharacters(in: .whitespacesAndNewlines) == String(shell) else {
            throw Failure("the first copy lost its session")
        }
        try d.run("exit")
    }),
    ("persist-cancel", "a cancelled quit leaves the persistent terminal working and its session alive", { d in
        d.quit()
        // With persistence a running command does not make quitting ask (it
        // keeps running), so the confirmation is forced to have one to cancel.
        let config = "session-persistence = true\nconfirm-close-surface = always\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid"))")
        guard let shell = Int32(try d.file("pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        try d.run("sleep 300")
        usleep(800_000)
        d.key(Key.q, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+q did not show confirmation dialog with Cancel button")
        }
        d.press(cancel)
        guard d.wait(for: { d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("quit confirmation dialog remained open after Cancel")
        }
        guard d.pid != 0, NSRunningApplication(processIdentifier: d.pid) != nil else {
            throw Failure("Tako quit although the quit was cancelled")
        }
        d.interrupt()
        try d.run("echo after > \(d.path("after"))")
        _ = try d.file("after")
        guard kill(shell, 0) == 0 else { throw Failure("the session's shell ended") }
        try d.run("exit")
    }),
    ("persist-reflow", "a restored persistent session reflows and updates columns when widened", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        d.setPosition(CGPoint(x: 20, y: 50))
        d.setSize(CGSize(width: 650, height: 500))
        d.focus()
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("cols_narrow"))")
        let narrow = Int(try d.file("cols_narrow").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard narrow > 0 && narrow < 95 else { throw Failure("narrow cols precondition failed: \(narrow)") }

        // Construct unique marker at runtime from distinct components and deliver via base64 decoding in Python
        // so no substring of the marker is ever typed into the shell command or command echo buffer.
        let p1 = "REFLOW_MARKER_PARTA_"
        let p2 = String(repeating: "J", count: 42)
        let p3 = "_SPLIT_MID_"
        let p4 = String(repeating: "K", count: 42)
        let expectedMarker = p1 + p2 + p3 + p4 // 115 chars
        let markerB64 = Data(expectedMarker.utf8).base64EncodedString()
        try d.run("python3 -c \"import base64, sys; sys.stdout.write(base64.b64decode('\(markerB64)').decode('utf-8') + '\\n')\"")
        usleep(1_000_000)

        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Precondition: In narrow terminal, the 115-char marker wraps and does NOT appear on any single line.
        // Also verify takoctl exit code succeeded via separate status witness.
        // Using --styled reads physical viewport rows rather than unstyled logical scrollback.
        try d.run("\(ctl) text --styled --lines 12 > \(d.path("narrow_text")) && echo OK > \(d.path("narrow_ok"))")
        guard try d.file("narrow_ok").trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw Failure("takoctl text failed at narrow width")
        }
        let narrowRows = (try? d.file("narrow_text"))?.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression).trimmingCharacters(in: .newlines)
        } ?? []
        guard !narrowRows.isEmpty && !narrowRows.allSatisfy({ $0.isEmpty }) else {
            throw Failure("precondition failed: narrowRows was empty!")
        }
        guard !narrowRows.contains(where: { $0.contains(expectedMarker) }) else {
            throw Failure("precondition failed: marker was not wrapped across physical rows in narrow \(narrow) columns. Rows were: \(narrowRows)")
        }
        // Verify physical row boundaries: prefix row must contain p1 and subsequent row must contain p4.suffix(20),
        // and together they reconstruct the full wrapped marker.
        guard let prefixIdx = narrowRows.firstIndex(where: { $0.contains(p1) }),
              prefixIdx + 1 < narrowRows.count,
              narrowRows[prefixIdx + 1].contains(p4.suffix(20)),
              (narrowRows[prefixIdx] + narrowRows[prefixIdx + 1]).contains(expectedMarker) else {
            throw Failure("precondition failed: could not identify physical wrapped row boundaries in narrow text: \(narrowRows)")
        }

        try d.quitNormally()

        try d.launch(config: config)
        d.setPosition(CGPoint(x: 20, y: 50))
        d.setSize(CGSize(width: 1250, height: 700))
        d.focus()
        usleep(1_500_000)

        try d.run("tput cols > \(d.path("cols_wide"))")
        let wide = Int(try d.file("cols_wide").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard wide > 120 && wide > narrow + 30 else {
            throw Failure("columns did not widen: was \(narrow), now \(wide)")
        }

        // Postcondition: Widening unwrapped the wrapped physical rows so the full 115-character marker
        // now fits onto a single physical terminal row.
        try d.run("\(ctl) text --styled --lines 50 > \(d.path("wide_text")) && echo OK > \(d.path("wide_ok"))")
        guard try d.file("wide_ok").trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw Failure("takoctl text failed at wide width")
        }
        let wideRows = (try? d.file("wide_text"))?.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression).trimmingCharacters(in: .newlines)
        } ?? []
        guard wideRows.contains(where: { $0.contains(expectedMarker) }) else {
            throw Failure("physical reflow failed: marker was not unwrapped into a single line in wide \(wide) columns. Rows were: \(wideRows)")
        }

        try d.run("exit")
    }),
    ("find-stale", "a match that changes, or a tab that closes, while it is being shown is reported where the user is", { d in
        // A long settle leaves time to change the target's output after it
        // has been brought forward and before the match is checked.
        d.quit()
        d.environment = ["TAKO_FIND_ALL_SETTLE": "6"]
        defer { d.environment = [:] }
        try d.launch()
        let id = d.work.lastPathComponent
        let marker = "stale-\(id)"
        for (index, (ending, notice)) in [("clear", "changed since the search"), ("exit", "has been closed")].enumerated() {
            // Tab A prints the match, then waits for the witness file before
            // wiping it (clear) or going away (exit): the test creates the
            // file only once it has seen tab A brought forward.
            let witness = d.path("go\(index)")
            try d.run("printf 'stale-%s\\n' \(id); sh -c 'while [ ! -e \(witness) ]; do sleep 0.2; done'; \(ending)")
            d.key(Key.t, .maskCommand)
            usleep(1_200_000)
            d.key(Key.f, [.maskCommand, .maskShift])
            usleep(600_000)
            // The panel keeps the last query; replace it.
            d.key(Key.a, .maskCommand)
            try d.type(marker)
            guard d.wait(for: { d.staticTexts().contains { $0.contains(marker) } }, timeout: 5) else {
                throw Failure("the match was never listed: \(d.staticTexts())")
            }
            d.key(Key.returnKey)
            // Tab A in front: its screen holds the marker.
            guard d.wait(for: { d.screenText().contains(marker) }, timeout: 5) else {
                throw Failure("Return did not bring the tab with the match forward")
            }
            FileManager.default.createFile(atPath: witness, contents: Data())

            guard d.wait(for: { d.staticTexts().contains { $0.contains(notice) } }, timeout: 15) else {
                throw Failure("after '\(ending)' no notice; texts: \(d.staticTexts())")
            }
            guard d.textFields().contains(marker) else {
                throw Failure("the search field is not shown with the query: \(d.textFields())")
            }
            // The list was searched again: the row for the gone match is gone.
            guard d.wait(for: { !d.staticTexts().contains { $0.contains(marker) } }, timeout: 5) else {
                throw Failure("the stale result is still listed: \(d.staticTexts())")
            }
            // Escape gives the keyboard back to a terminal.
            d.key(Key.escape)
            usleep(500_000)
            try d.run("tty > \(d.path("back\(index)"))")
            guard (try? d.file("back\(index)")) != nil else {
                throw Failure("after Escape the keyboard did not reach a terminal")
            }
            try d.run("clear")
        }
    }),
    ("new-tab", "cmd+t opens a tab that takes the keyboard; exit closes it and gives it back", { d in
        // Native window tabs share one accessibility window, so a new tab is
        // a new terminal (its own tty) in the same number of windows.
        try d.run("tty > \(d.path("tty1"))")
        let first = try d.file("tty1")
        let windows = d.windows().count
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty2"))")
        let second = try d.file("tty2")
        guard first != second else { throw Failure("typing after cmd+t still went to the first terminal (\(first))") }
        guard d.windows().count == windows else {
            throw Failure("cmd+t opened a window, not a tab (\(windows) windows before, \(d.windows().count) after)")
        }
        try d.run("exit")
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty3"))")
        guard try d.file("tty3") == first else {
            throw Failure("after the tab's shell exited the keyboard did not go back to the first terminal")
        }
    }),
    ("split", "cmd+d splits, and the new pane has its own terminal and the keyboard", { d in
        try d.run("tty > \(d.path("pane1"))")
        let first = try d.file("pane1")
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        try d.run("tty > \(d.path("pane2"))")
        let second = try d.file("pane2")
        guard first != second else { throw Failure("typing after cmd+d still went to the first pane") }
    }),
    ("zoom", "cmd+= makes the font bigger, which the program sees as fewer columns", { d in
        try d.run("tput cols > \(d.path("cols1"))")
        let before = Int(try d.file("cols1").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.key(Key.equal, .maskCommand)
        d.key(Key.equal, .maskCommand)
        usleep(800_000)
        try d.run("tput cols > \(d.path("cols2"))")
        let bigger = Int(try d.file("cols2").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard bigger < before else { throw Failure("zoomed in: \(before) columns before, \(bigger) after") }
        d.key(Key.zero, .maskCommand)
        usleep(800_000)
        try d.run("tput cols > \(d.path("cols3"))")
        let reset = Int(try d.file("cols3").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard reset == before else { throw Failure("cmd+0: \(before) columns at first, \(reset) after reset") }
    }),
    ("resize", "a smaller window is a smaller terminal for the program", { d in
        // A new window may open at the size the last one closed with, which
        // can be this scenario's own small one; start from a known large one.
        d.setSize(CGSize(width: 900, height: 600))
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("wide"))")
        let wide = Int(try d.file("wide").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.setSize(CGSize(width: 420, height: 320))
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("narrow"))")
        let narrow = Int(try d.file("narrow").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard narrow > 0, narrow < wide else { throw Failure("resized: \(wide) columns before, \(narrow) after") }
    }),
    ("paste", "cmd+v pastes the clipboard into the shell as typed text", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("pasted  text", forType: .string)
        try d.type("printf '%s' '")
        d.key(Key.v, .maskCommand)
        usleep(500_000)
        try d.run("' > \(d.path("pasted"))")
        try d.expect("pasted", "pasted  text", "paste")
    }),
    ("paste-utf8", "cmd+v pastes utf8 text correctly", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("кириллица 👋 123", forType: .string)
        try d.type("printf '%s' '")
        d.key(Key.v, .maskCommand)
        usleep(500_000)
        try d.run("' > \(d.path("pasted-utf8"))")
        try d.expect("pasted-utf8", "кириллица 👋 123", "paste-utf8")
    }),
    ("close-busy", "closing a terminal that is running something asks first", { d in
        try d.run("sleep 30")
        usleep(800_000)
        let windows = d.windows().count
        d.key(Key.w, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+w closed a terminal running sleep without asking (\(d.windows().count) of \(windows) windows left)")
        }
        d.press(cancel)
        usleep(500_000)
        guard d.windows().count == windows else { throw Failure("Cancel still closed the window") }
        d.key(Key.c, .maskControl)
        try d.run("echo alive > \(d.path("alive"))")
        try d.expect("alive", "alive\n", "the terminal after Cancel")
    }),
    ("copy", "a double-click selects a word and cmd+c copies it", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        try d.run("tput lines > \(d.path("lines")); tput cols > \(d.path("cols"))")
        let rows = Int(try d.file("lines").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let cols = Int(try d.file("cols").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // A screenful of the word, so the click lands on it whatever the
        // prompt looks like.
        try d.run("clear; yes copyme | head -n \(rows * 2)")
        usleep(800_000)
        guard rows > 0, cols > 0, let frame = d.terminalFrame() else { throw Failure("no terminal geometry") }
        let cell = CGSize(width: frame.width / CGFloat(cols), height: frame.height / CGFloat(rows))
        let point = CGPoint(x: frame.minX + cell.width * 2.5, y: frame.minY + cell.height * 2.5)
        try d.click(at: point, count: 2)
        usleep(300_000)
        guard d.menuItemEnabled("Copy") == true else {
            throw Failure("a double-click on a word selected nothing (Edit > Copy is disabled)")
        }
        d.key(Key.c, .maskCommand)
        guard d.wait(for: { pasteboard.string(forType: .string) == "copyme" }, timeout: 3) else {
            throw Failure("the clipboard holds \(pasteboard.string(forType: .string).map(hex) ?? "nothing"), not the double-clicked word")
        }
    }),
    ("quit-busy", "cmd+q while a command runs asks first, and Cancel keeps everything", { d in
        try d.run("sleep 30")
        usleep(800_000)
        d.key(Key.q, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure(d.isRunning ? "cmd+q asked nothing" : "cmd+q quit with a command running, without asking")
        }
        d.press(cancel)
        usleep(500_000)
        guard d.isRunning else { throw Failure("Cancel still quit") }
        d.key(Key.c, .maskControl)
        try d.run("echo alive > \(d.path("alive"))")
        try d.expect("alive", "alive\n", "the terminal after Cancel")
    }),
    ("config", "the config file is read, and Reload Configuration applies a change to the open terminal", { d in
        d.quit()
        try d.launch(config: Driver.defaultConfig + "font-size = 12\n")
        try d.run("tput cols > \(d.path("small"))")
        let small = Int(try d.file("small").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.quit()
        try d.launch(config: Driver.defaultConfig + "font-size = 24\n")
        try d.run("tput cols > \(d.path("large"))")
        let large = Int(try d.file("large").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard large > 0, large < small else { throw Failure("font-size 12 gave \(small) columns, 24 gave \(large)") }

        try "font-size = 12\n".write(toFile: d.path("config"), atomically: true, encoding: .utf8)
        d.key(Key.comma, [.maskCommand, .maskShift])
        usleep(1_200_000)
        try d.run("tput cols > \(d.path("reloaded"))")
        let reloaded = Int(try d.file("reloaded").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard reloaded > large else {
            throw Failure("after reloading font-size 12 the terminal still has \(reloaded) columns (24pt had \(large))")
        }
    }),
    ("padding", "window-padding-x takes columns away from the program", { d in
        func cols(_ config: String, _ name: String) throws -> Int {
            d.quit()
            try d.launch(config: Driver.defaultConfig + config)
            try d.run("tput cols > \(d.path(name))")
            return Int(try d.file(name).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let none = try cols("window-padding-x = 0\n", "pad0")
        let wide = try cols("window-padding-x = 100\n", "pad100")
        guard wide > 0, wide < none else { throw Failure("padding 0 gave \(none) columns, padding 100 gave \(wide)") }
    }),
    ("split-focus", "cmd+] moves the keyboard to the next split and back round", { d in
        try d.run("tty > \(d.path("sf1"))")
        let first = try d.file("sf1")
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        try d.run("tty > \(d.path("sf2"))")
        let second = try d.file("sf2")
        guard second != first else { throw Failure("cmd+d did not give the new split the keyboard") }
        d.key(Key.rightBracket, .maskCommand)
        usleep(800_000)
        try d.run("tty > \(d.path("sf3"))")
        guard try d.file("sf3") == first else { throw Failure("cmd+] did not move the keyboard to the other split") }
    }),
    ("quit-idle", "cmd+q with nothing running quits without asking", { d in
        d.key(Key.q, .maskCommand)
        guard d.wait(for: { !d.isRunning }, timeout: 8) else {
            let asked = d.button(titled: "Cancel") != nil
            throw Failure(asked ? "cmd+q asked although nothing was running" : "cmd+q did not quit")
        }
    }),
    ("new-window", "cmd+n opens a second window with its own terminal and the keyboard", { d in
        try d.run("tty > \(d.path("win1"))")
        let first = try d.file("win1")
        let windows = d.windows().count
        d.key(Key.n, .maskCommand)
        guard d.wait(for: { d.windows().count == windows + 1 }, timeout: 5) else {
            throw Failure("cmd+n: \(windows) windows before, \(d.windows().count) after")
        }
        usleep(1_000_000)
        try d.run("tty > \(d.path("win2"))")
        guard try d.file("win2") != first else { throw Failure("typing after cmd+n went to the old window") }
    }),
    ("settings", "cmd+, opens the in-terminal settings dialog, and Esc dismisses it", { d in
        d.key(Key.comma, .maskCommand)
        var closeBtn: AXUIElement?
        guard d.wait(for: { closeBtn = d.button(titled: "Close"); return closeBtn != nil }, timeout: 5) else {
            throw Failure("cmd+, did not present the settings dialog (Close button not found)")
        }
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss the settings dialog")
        }
    }),
    ("settings-record", "settings shortcut recorder activates, cancels on Esc, records custom shortcut, verifies runtime binding, and resets to default", { d in
        d.key(Key.comma, .maskCommand)
        var recordBtn: AXUIElement?
        guard d.wait(for: { recordBtn = d.button(titled: "Record"); return recordBtn != nil }, timeout: 5),
              let recordBtn else {
            throw Failure("settings dialog Record button not found")
        }
        guard d.button(titled: "Close") != nil else {
            throw Failure("settings dialog Close button not found")
        }
        // Test recording mode activation via Record button
        d.press(recordBtn)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") || d.hasText(containing: "cancel") }, timeout: 5) else {
            throw Failure("settings dialog did not enter recording state after pressing Record")
        }
        // In recording mode, first Esc cancels recording without modifying keybindings or closing settings
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") != nil && (d.hasText(containing: "cancelled") || !d.hasText(containing: "recording")) }, timeout: 5) else {
            throw Failure("first Escape did not cancel recording while leaving Settings dialog open")
        }
        // Activate recording again via key 'r'
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("settings dialog did not enter recording state after pressing 'r'")
        }
        // Record custom shortcut: Cmd+Opt+Ctrl+K on New Tab (row 0)
        d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
        guard d.wait(for: { d.hasText(containing: "custom") || d.hasText(containing: "Updated") }, timeout: 5) else {
            throw Failure("custom shortcut was not saved and applied in settings dialog")
        }

        // Dismiss settings dialog via Esc to test runtime shortcut
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after recording")
        }

        // Verify runtime behavior: record initial TTY
        try d.run("tty > \(d.path("rec_tty1"))")
        let firstTty = try d.file("rec_tty1").trimmingCharacters(in: .whitespacesAndNewlines)

        // Invoke custom shortcut: Cmd+Opt+Ctrl+K -> opens new tab
        d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
        usleep(1_200_000)
        try d.run("tty > \(d.path("rec_tty2"))")
        let secondTty = try d.file("rec_tty2").trimmingCharacters(in: .whitespacesAndNewlines)
        guard secondTty != firstTty else {
            throw Failure("custom shortcut Cmd+Opt+Ctrl+K did not open a new tab with its own TTY")
        }

        // Close created tab and verify focus returns to first tab
        try d.run("exit")
        usleep(1_200_000)
        try d.run("tty > \(d.path("rec_tty3"))")
        guard (try? d.file("rec_tty3").trimmingCharacters(in: .whitespacesAndNewlines)) == firstTty else {
            throw Failure("focus did not return to initial tab after exiting custom-opened tab")
        }

        // Reopen settings dialog to reset to default
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("failed to reopen settings dialog for reset")
        }

        // Reset selected keybinding back to default via key 'd'
        d.key(Key.d)
        guard d.wait(for: { d.hasText(containing: "Reset") || d.hasText(containing: "default") }, timeout: 5) else {
            throw Failure("Reset action failed to restore default keybinding")
        }
        // Esc closes settings dialog
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Record") == nil && d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after reset")
        }

        // Verify runtime behavior after reset:
        // 1. Custom shortcut Cmd+Opt+Ctrl+K must no longer open a tab (no-op)
        d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
        usleep(800_000)
        try d.run("tty > \(d.path("rec_tty4"))")
        guard (try? d.file("rec_tty4").trimmingCharacters(in: .whitespacesAndNewlines)) == firstTty else {
            throw Failure("custom shortcut Cmd+Opt+Ctrl+K still opened a tab after being reset to default")
        }

        // 2. Default shortcut Cmd+T opens a tab
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        try d.run("tty > \(d.path("rec_tty5"))")
        let defTty = try d.file("rec_tty5").trimmingCharacters(in: .whitespacesAndNewlines)
        guard defTty != firstTty else {
            throw Failure("default shortcut Cmd+T did not open a tab after reset")
        }
        try d.run("exit")
        usleep(1_200_000)

        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'settings_ok' > \(d.path("settings_witness"))")
        try d.expect("settings_witness", "settings_ok\n", "terminal keyboard input after settings dismissal")
    }),
    ("settings-conflict", "settings detects shortcut conflict, supports cancel (Esc) and confirm overwrite (Return) with verified runtime actions", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not open")
        }
        // Start recording on New Tab (row 0)
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("did not enter recording mode")
        }
        // Enter a shortcut known to conflict with another default action: Cmd+D (Split Right)
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { d.hasText(containing: "Conflict:") && d.hasText(containing: "Overwrite? (Return=Yes, Esc=No)") }, timeout: 5) else {
            throw Failure("conflict warning banner was not displayed for conflicting shortcut Cmd+D")
        }

        // Step 1: Cancel conflict reassignment via Escape
        d.key(Key.escape)
        guard d.wait(for: { d.hasText(containing: "Reassignment cancelled.") || d.hasText(containing: "cancelled") }, timeout: 5) else {
            throw Failure("Escape did not cancel conflict reassignment")
        }
        // Dismiss settings to prove NO CHANGE occurred at runtime
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after cancelled conflict")
        }

        try d.run("tty > \(d.path("conf_tty1"))")
        let firstTty = try d.file("conf_tty1").trimmingCharacters(in: .whitespacesAndNewlines)

        // Prove Cmd+D still performs Split Right
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        try d.run("tty > \(d.path("conf_split_tty"))")
        let splitTty = try d.file("conf_split_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard splitTty != firstTty else {
            throw Failure("Cmd+D did not perform split right after cancelled conflict")
        }
        let treeSplitCheck = try d.exec("\(ctl) tree --json")
        guard treeSplitCheck.contains("\"split\"") else {
            throw Failure("Cmd+D did not create split pane after cancelled conflict: \(treeSplitCheck)")
        }
        d.closeTab()
        usleep(1_200_000)

        // Prove Cmd+T still performs New Tab
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        d.activate()
        try d.run("tty > \(d.path("conf_tab_tty"))")
        let tabTty = try d.file("conf_tab_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard tabTty != firstTty else {
            throw Failure("Cmd+T did not open tab after cancelled conflict")
        }
        d.closeTab()
        usleep(1_200_000)

        // Step 2: Record again and confirm reassignment via Return
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not reopen for second pass")
        }
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("did not enter recording mode for second pass")
        }
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { d.hasText(containing: "Conflict:") }, timeout: 5) else {
            throw Failure("conflict warning banner was not displayed on second pass")
        }
        d.key(Key.returnKey)
        guard d.wait(for: { d.hasText(containing: "Reassigned") || d.hasText(containing: "custom") || d.hasText(containing: "Updated") }, timeout: 5) else {
            throw Failure("Return did not confirm and apply reassignment")
        }
        // Dismiss settings to prove UNIQUE OWNERSHIP
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after reassignment")
        }

        d.activate()
        try d.run("tty > \(d.path("conf_owner_tty1"))")
        let baseTty = try d.file("conf_owner_tty1").trimmingCharacters(in: .whitespacesAndNewlines)

        // Press Cmd+D: now assigned to New Tab; must open a tab and NOT a split!
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        d.activate()
        try d.run("tty > \(d.path("conf_owner_tty2"))")
        let ownerTty = try d.file("conf_owner_tty2").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ownerTty != baseTty else {
            throw Failure("Cmd+D did not take effect after being reassigned to New Tab")
        }
        let treeOwner = try d.exec("\(ctl) tree --json")
        guard !treeOwner.contains("\"split\"") else {
            throw Failure("Cmd+D created split pane instead of tab after reassignment to New Tab: \(treeOwner)")
        }
        d.closeTab()
        usleep(1_200_000)

        // Step 3: Reopen settings, reset to default via 'd', dismiss and prove default behavior restored
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not reopen for reset")
        }
        d.key(Key.d)
        guard d.wait(for: { d.hasText(containing: "Reset") || d.hasText(containing: "default") }, timeout: 5) else {
            throw Failure("Reset action failed to restore default keybinding")
        }
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after reset")
        }

        // Prove Cmd+D restores Split Right
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        let treeResetSplit = try d.exec("\(ctl) tree --json")
        guard treeResetSplit.contains("\"split\"") else {
            throw Failure("Cmd+D did not perform split right after reset: \(treeResetSplit)")
        }
        d.closeTab()
        usleep(1_200_000)

        // Prove Cmd+T performs New Tab
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        d.activate()
        try d.run("tty > \(d.path("conf_reset_tab"))")
        let tabResetTty = try d.file("conf_reset_tab").trimmingCharacters(in: .whitespacesAndNewlines)
        guard tabResetTty != baseTty else {
            throw Failure("Cmd+T did not perform new tab after reset")
        }
        d.closeTab()
        usleep(1_200_000)

        // Unassisted keyboard delivery to terminal pane afterwards
        d.activate()
        usleep(400_000)
        try d.run("echo 'conflict_ok' > \(d.path("conflict_witness"))")
        try d.expect("conflict_witness", "conflict_ok\n", "terminal keyboard input after conflict dialog flow")
    }),
    ("modal-containment", "modal settings dialog blocks keystrokes and shortcuts from leaking to underlying terminal PTY", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not open for modal containment test")
        }
        // Attempt typing command into terminal while modal is active
        let leakFile = d.path("containment_leak.txt")
        try d.run("echo 'leaked_to_pty' > \(leakFile)")
        // Attempt split shortcut (Cmd+D) while modal is active: must be blocked by performKeyEquivalent
        d.key(Key.d, .maskCommand)
        usleep(400_000)

        // Verify no split pane was created
        let tree = try d.exec("\(ctl) tree --json")
        guard !tree.contains("\"split\"") else {
            throw Failure("Cmd+D leaked through modal dialog and created a split pane: \(tree)")
        }
        // Verify terminal PTY received no leaked keystrokes
        guard !FileManager.default.fileExists(atPath: leakFile) else {
            throw Failure("keystrokes leaked through modal dialog to terminal PTY")
        }

        // Dismiss settings dialog
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog")
        }
        // Verify terminal PTY input recovers cleanly
        let recoveredFile = d.path("containment_recovered.txt")
        try d.run("echo 'containment_ok' > \(recoveredFile)")
        try d.expect("containment_recovered.txt", "containment_ok\n", "terminal keyboard input recovery after modal dismissal")
    }),
    ("settings-terminal-effects", "settings dialog switches to Terminal Settings tab, exercises search responder handoff, toggles runtime setting, updates config, and resets cleanly", { d in
        d.key(Key.comma, .maskCommand)
        var closeBtn: AXUIElement?
        guard d.wait(for: { closeBtn = d.button(titled: "Close"); return closeBtn != nil }, timeout: 5) else {
            throw Failure("cmd+, did not present the settings dialog (Close button not found)")
        }
        guard let dialog = d.element(withIdentifier: "TerminalSettingsDialog") else {
            throw Failure("TerminalSettingsDialog accessibility element not found")
        }

        // Switch to Tab 2: Terminal Settings via Cmd+2
        d.key(Key.two, .maskCommand)
        guard d.wait(for: {
            let val: String? = d.attribute(dialog, kAXValueAttribute)
            return val?.contains("Terminal Settings") == true
        }, timeout: 5) else {
            throw Failure("Cmd+2 did not switch to Terminal Settings tab")
        }

        // Locate search field and its screen coordinates
        guard let searchField = d.descendants(of: dialog, role: kAXTextFieldRole).first else {
            throw Failure("search field not found in settings dialog")
        }
        guard let sfPos: AXValue = d.attribute(searchField, kAXPositionAttribute),
              let sfSize: AXValue = d.attribute(searchField, kAXSizeAttribute) else {
            throw Failure("could not read search field frame coordinates")
        }
        var sfOrigin = CGPoint.zero
        var sfExtent = CGSize.zero
        AXValueGetValue(sfPos, .cgPoint, &sfOrigin)
        AXValueGetValue(sfSize, .cgSize, &sfExtent)

        // 1. Focus search field by clicking inside it and type a query with zero results
        try d.click(at: CGPoint(x: sfOrigin.x + 20, y: sfOrigin.y + sfExtent.height / 2))
        usleep(200_000)
        try d.type("nonexistentqueryxyz")
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let searchField = d.descendants(of: curDialog, role: kAXTextFieldRole).first,
                  let searchVal: String = d.attribute(searchField, kAXValueAttribute),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return searchVal == "nonexistentqueryxyz" &&
                   val.contains("Terminal Settings: 0 items") &&
                   val.contains("No matching settings")
        }, timeout: 5) else {
            let val: String = d.element(withIdentifier: "TerminalSettingsDialog").flatMap { d.attribute($0, kAXValueAttribute) } ?? "nil"
            throw Failure("nonexistent search query did not produce exact zero-result state in dialog (dialog AXValue: '\(val)')")
        }

        // 2. Escape in search field clears active query and recovers full list
        d.key(Key.escape)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let searchField = d.descendants(of: curDialog, role: kAXTextFieldRole).first,
                  let searchVal: String = d.attribute(searchField, kAXValueAttribute),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return searchVal.isEmpty && val.contains("Terminal Settings: 24 items") && val.contains("Sync Window Frame")
        }, timeout: 5) else {
            throw Failure("Escape in search field did not clear search text and recover full 24 settings list")
        }

        // 3. Type "sync" to filter to workspace sync setting
        try d.type("sync")
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let searchField = d.descendants(of: curDialog, role: kAXTextFieldRole).first,
                  let searchVal: String = d.attribute(searchField, kAXValueAttribute),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return searchVal == "sync" && val.contains("Sync Window Frame")
        }, timeout: 5) else {
            throw Failure("typing 'sync' did not filter to Sync Window Frame setting")
        }

        // 4. Test mouse-to-keyboard focus handoff:
        // Click on the list item row (Row 5 is 3.5 row heights below search field at Row 2)
        let clickPt = CGPoint(x: sfOrigin.x + 50, y: sfOrigin.y + 3.5 * sfExtent.height)
        try d.click(at: clickPt)
        usleep(300_000)

        // Now send Space to toggle setting (Space toggles/cycles setting when dialog is focused)
        d.key(Key.space)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return val == "setting_custom_success: workspace-sync-window-frame" ||
                   val.contains("Custom: workspace-sync-window-frame = true")
        }, timeout: 5) else {
            throw Failure("Space key after mouse click did not toggle filtered setting to custom=true")
        }

        // Verify search field string value remained "sync"
        let searchVal: String = d.attribute(searchField, kAXValueAttribute) ?? ""
        guard searchVal == "sync" else {
            throw Failure("search field text was corrupted or lost during mouse handoff: \(searchVal)")
        }

        // Dismiss settings dialog via Esc
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog")
        }

        // Verify config file on disk now contains the persisted setting override (fail-closed read)
        let configPath = d.path("config")
        let configContent = try String(contentsOfFile: configPath, encoding: .utf8)
        let configLines = configContent.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard configLines.contains("workspace-sync-window-frame = true") else {
            throw Failure("config file was not updated with workspace-sync-window-frame = true: \(configContent)")
        }

        // 5. Reopen settings dialog to reset setting
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("failed to reopen settings dialog for reset")
        }
        d.key(Key.two, .maskCommand) // switch to Terminal Settings tab
        usleep(300_000)

        // Press 'd' to reset setting
        d.key(Key.d)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return val == "setting_reset_success: workspace-sync-window-frame" ||
                   val.contains("Reset to default: workspace-sync-window-frame")
        }, timeout: 5) else {
            throw Failure("pressing 'd' did not reset setting")
        }

        // Dismiss settings
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after reset")
        }

        // Verify config file no longer contains the custom override (fail-closed read)
        let resetConfigContent = try String(contentsOfFile: configPath, encoding: .utf8)
        let resetLines = resetConfigContent.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !resetLines.contains(where: { $0.hasPrefix("workspace-sync-window-frame") || $0.hasPrefix("workspace-inherit-window-frame") }) else {
            throw Failure("config file still contained override after reset: \(resetConfigContent)")
        }

        // Verify terminal unassisted keyboard delivery
        try d.run("echo 'settings_effects_ok' > \(d.path("settings_effects_witness"))")
        try d.expect("settings_effects_witness", "settings_effects_ok\n", "terminal keyboard input after settings effect journey")
    }),
    ("sidebar", "cmd+opt+s toggles the session sidebar open and closed", { d in
        d.key(Key.s, [.maskCommand, .maskAlternate])
        guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 5) else {
            throw Failure("session sidebar 'Sessions' header was not visible after Cmd+Opt+S")
        }
        // Toggle again to return to normal
        d.key(Key.s, [.maskCommand, .maskAlternate])
        guard d.wait(for: { !d.hasText(containing: "Sessions") }, timeout: 5) else {
            throw Failure("session sidebar was still visible after second Cmd+Opt+S")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'sidebar_ok' > \(d.path("sidebar_witness"))")
        try d.expect("sidebar_witness", "sidebar_ok\n", "terminal keyboard input after sidebar toggle")
    }),
    ("overview", "cmd+shift+o toggles pane overview on, and Esc dismisses it", { d in
        d.key(Key.o, [.maskCommand, .maskShift])
        guard d.wait(for: { d.hasText(containing: "Pane Overview") }, timeout: 5) else {
            throw Failure("pane overview header was not visible after Cmd+Shift+O")
        }
        d.key(Key.escape)
        guard d.wait(for: { !d.hasText(containing: "Pane Overview") }, timeout: 5) else {
            throw Failure("pane overview was still visible after Escape")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'overview_ok' > \(d.path("overview_witness"))")
        try d.expect("overview_witness", "overview_ok\n", "terminal keyboard input after overview dismissal")
    }),
    ("workspace-switch", "takoctl workspace commands create, list, and switch project workspaces", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        _ = try d.exec("\(ctl) workspace create E2EWS")
        let list = try d.exec("\(ctl) workspace list")
        guard list.contains("E2EWS") else {
            throw Failure("workspace list did not contain newly created workspace: \(list)")
        }
        _ = try d.exec("\(ctl) workspace switch E2EWS")
        let currE2E = try d.exec("\(ctl) workspace current")
        guard currE2E.contains("E2EWS") else {
            throw Failure("workspace current was not E2EWS after switch: \(currE2E)")
        }
        _ = try d.exec("\(ctl) workspace switch Default")
        let currDef = try d.exec("\(ctl) workspace current")
        guard currDef.contains("Default") else {
            throw Failure("workspace current was not Default after switch back: \(currDef)")
        }
        _ = try d.exec("\(ctl) workspace delete E2EWS")
    }),
    ("workspace-move-keeps-sessions", "a tab moved to another workspace by takoctl, and the switch to it, leave its long-running process alive and listed", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // A second tab running something long, like a tail -f left open.
        let pane = try d.exec("\(ctl) tab-new --no-select").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pane.isEmpty else { throw Failure("tab-new printed no pane id") }
        let pidFile = d.path("moved.pid")
        // The tab's shell is fish, where $$ means nothing: sh writes its own pid.
        _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(pidFile); exec sleep 600'\" --target \(pane)")
        let pid = try d.file("moved.pid").trimmingCharacters(in: .whitespacesAndNewlines)
        func alive() -> Bool { (try? d.exec("kill -0 \(pid)")) != nil }
        guard alive() else { throw Failure("the long-running process never started (pid \(pid))") }

        _ = try d.exec("\(ctl) workspace create E2EMove")
        _ = try d.exec("\(ctl) workspace assign --workspace E2EMove --target \(pane)")
        let listed = try d.exec("\(ctl) --json workspace list")
        guard listed.contains("E2EMove") else { throw Failure("no E2EMove in \(listed)") }
        guard alive() else { throw Failure("assigning the tab ended its process") }

        _ = try d.exec("\(ctl) workspace switch E2EMove")
        usleep(1_500_000)
        guard alive() else { throw Failure("switching to the workspace the tab was moved to ended its process") }
        let tree = try d.exec("\(ctl) tree")
        guard tree.contains(String(pane.prefix(8))) else {
            throw Failure("the moved tab is not in the tree after the switch: \(tree)")
        }

        _ = try d.exec("\(ctl) workspace switch Default")
        usleep(1_500_000)
        guard alive() else { throw Failure("switching back ended the process") }
        _ = try d.exec("\(ctl) workspace switch E2EMove")
        usleep(1_000_000)
        guard alive() else { throw Failure("a second switch ended the process") }
        _ = try d.exec("\(ctl) workspace switch Default")
        _ = try d.exec("kill \(pid)")
        _ = try d.exec("\(ctl) workspace delete E2EMove")
    }),
    ("workspace-tabs-stay-visible", "agent tabs and terminals in three workspaces stay listed in the open session sidebar, keep their processes and statuses, and show only their own windows through switches by takoctl and by sidebar clicks", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // One tab per entry: a long-running process, and for agents the status their hooks would set.
        struct Spec { let title: String; let workspace: String; let status: String?; let command: String }
        let log = d.path("ws-visible.log")
        try "start\n".write(toFile: log, atomically: true, encoding: .utf8)
        let specs = [
            Spec(title: "E2E Claude agent", workspace: "Default", status: "working", command: "exec sleep 600"),
            Spec(title: "E2E tail log", workspace: "Default", status: nil, command: "exec tail -f \(log)"),
            Spec(title: "E2E Codex agent", workspace: "E2ELegal", status: "needs_approval", command: "exec sleep 600"),
            Spec(title: "E2E Antigravity agent", workspace: "E2ELegal", status: "working", command: "exec sleep 600"),
            Spec(title: "E2E Vite server", workspace: "E2EFront", status: "waiting_for_input", command: "exec sleep 600"),
            Spec(title: "E2E front shell", workspace: "E2EFront", status: nil, command: "exec tail -f \(log)"),
        ]
        // A run that failed before its cleanup leaves its workspaces behind, and
        // creating one whose name is taken adds a number ("E2ELegal 2").
        func deleteOurWorkspaces() {
            _ = try? d.exec("\(ctl) workspace switch Default")
            for ws in (try? d.workspaceList()) ?? [] {
                guard let name = ws["name"] as? String, name.hasPrefix("E2ELegal") || name.hasPrefix("E2EFront") else { continue }
                _ = try? d.exec("\(ctl) workspace delete \"\(name)\"")
            }
        }
        deleteOurWorkspaces()
        _ = try d.exec("\(ctl) workspace create E2ELegal")
        _ = try d.exec("\(ctl) workspace create E2EFront")
        var panes: [String: String] = [:], pids: [String: String] = [:]
        var sidebarWasOpen = true
        defer {
            for pid in pids.values { _ = try? d.exec("kill \(pid)") }
            _ = try? d.exec("\(ctl) workspace switch Default")
            for pane in panes.values { _ = try? d.exec("\(ctl) close --target \(pane)") }
            deleteOurWorkspaces()
            if !sidebarWasOpen { d.key(Key.s, [.maskCommand, .maskAlternate]) }
        }
        for (i, spec) in specs.enumerated() {
            let pane = trimmed(try d.exec("\(ctl) tab-new --no-select"))
            guard !pane.isEmpty else { throw Failure("tab-new printed no pane id for \(spec.title)") }
            let pidFile = d.path("ws-visible-\(i).pid")
            _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(pidFile); \(spec.command)'\" --target \(pane)")
            pids[spec.title] = trimmed(try d.file("ws-visible-\(i).pid"))
            _ = try d.exec("\(ctl) title \"\(spec.title)\" --target \(pane)")
            if let status = spec.status { _ = try d.exec("\(ctl) status set \(status) --target \(pane)") }
            if spec.workspace != "Default" {
                _ = try d.exec("\(ctl) workspace assign --workspace \(spec.workspace) --target \(pane)")
            }
            panes[spec.title] = pane
        }
        // Room for the whole list: a row scrolled out of sight is not "shown".
        d.setPosition(CGPoint(x: 60, y: 40))
        d.setSize(CGSize(width: 1100, height: 900))
        // The sidebar, open in the window the user is in. Its visibility is
        // app-wide and kept, so it may be open already.
        d.activate()
        sidebarWasOpen = d.hasText(containing: "Sessions")
        if !sidebarWasOpen { d.key(Key.s, [.maskCommand, .maskAlternate]) }
        guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 5) else {
            throw Failure("the session sidebar did not open (\(d.debugFocusState()))")
        }

        var windowsOf: [String: Set<CGWindowID>] = [:]
        /// The element whose text is `text`, if it lies inside the on-screen window it belongs to.
        func visibleElement(_ text: String) -> (element: AXUIElement, frame: CGRect)? {
            for window in d.onScreenWindows() {
                guard let windowFrame = d.windowFrame(window) else { continue }
                for role in [kAXStaticTextRole as String, kAXButtonRole as String] {
                    for element in d.descendants(of: window, role: role) {
                        let value: String? = d.attribute(element, kAXValueAttribute)
                        let title: String? = d.attribute(element, kAXTitleAttribute)
                        guard let shown = value ?? title, shown.caseInsensitiveCompare(text) == .orderedSame || shown.contains(text),
                              let posValue: AXValue = d.attribute(element, kAXPositionAttribute),
                              let sizeValue: AXValue = d.attribute(element, kAXSizeAttribute) else { continue }
                        var pos = CGPoint.zero, size = CGSize.zero
                        AXValueGetValue(posValue, .cgPoint, &pos)
                        AXValueGetValue(sizeValue, .cgSize, &size)
                        let frame = CGRect(origin: pos, size: size)
                        if size.width > 0, size.height > 0, windowFrame.contains(frame) { return (element, frame) }
                    }
                }
            }
            return nil
        }
        func check(_ workspace: String, how: String) throws {
            let current = try d.workspaceCurrent()?["name"] as? String
            guard current == workspace else { throw Failure("\(how): current workspace is \(current ?? "none"), not \(workspace)") }
            guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 4) else {
                throw Failure("\(how): the session sidebar is not on screen after switching to \(workspace)")
            }
            // Each workspace keeps its own window frame: give this one the room too.
            if let window = d.activeOnScreenWindow() {
                d.setPosition(CGPoint(x: 60, y: 40), for: window)
                d.setSize(CGSize(width: 1100, height: 900), for: window)
                usleep(300_000)
            }
            for spec in specs {
                guard d.wait(for: { visibleElement(spec.title) != nil }, timeout: 4) else {
                    throw Failure("\(how): the sidebar on screen does not show \(spec.title) (\(spec.workspace)) while in \(workspace)")
                }
                guard let pid = pids[spec.title], (try? d.exec("kill -0 \(pid)")) != nil else {
                    throw Failure("\(how): the process of \(spec.title) ended after switching to \(workspace)")
                }
                if let status = spec.status, let pane = panes[spec.title] {
                    let got = try d.exec("\(ctl) status get --target \(pane)")
                    guard got.hasPrefix(status) else {
                        throw Failure("\(how): \(spec.title) lost its status \(status) after switching to \(workspace): \(trimmed(got))")
                    }
                }
            }
            let tree = try d.exec("\(ctl) tree")
            for (title, pane) in panes where !tree.contains(String(pane.prefix(8))) {
                throw Failure("\(how): \(title)'s pane is missing from the tree in \(workspace)")
            }
            func titles(_ ids: Set<CGWindowID>) -> String {
                d.windows().compactMap { w -> String? in
                    guard let id = d.windowID(for: w), ids.contains(id) else { return nil }
                    return "\(id):\((d.attribute(w, kAXTitleAttribute) as String?) ?? "?")"
                }.joined(separator: ", ")
            }
            // Windows of other workspaces leave the screen; give a fade its time.
            var onScreen = d.onScreenWindowNumbers()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline,
                  windowsOf.contains(where: { $0.key != workspace && !$0.value.isDisjoint(with: onScreen) }) {
                usleep(100_000)
                onScreen = d.onScreenWindowNumbers()
            }
            guard !onScreen.isEmpty else { throw Failure("\(how): no window of \(workspace) is on screen") }
            if let seen = windowsOf[workspace], seen != onScreen {
                throw Failure("\(how): \(workspace) came back with other windows on screen: [\(titles(onScreen))] vs [\(titles(seen))]")
            }
            for (other, theirs) in windowsOf where other != workspace && !theirs.isDisjoint(with: onScreen) {
                throw Failure("\(how): 3 s after switching to \(workspace), a window of \(other) is still on screen: on screen [\(titles(onScreen))], \(other) had [\(titles(theirs))]")
            }
            windowsOf[workspace] = onScreen
        }

        try check("Default", how: "start")
        for target in ["E2ELegal", "E2EFront", "Default", "E2EFront", "E2ELegal", "Default"] {
            _ = try d.exec("\(ctl) workspace switch \(target)")
            usleep(800_000)
            try check(target, how: "takoctl switch")
        }
        // A click on the workspace's header in the sidebar switches too.
        func clickSidebarText(_ text: String) throws {
            guard let (_, frame) = visibleElement(text) else { throw Failure("no \(text) header in the sidebar on screen") }
            try d.click(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        for target in ["E2EFront", "E2ELegal", "Default"] {
            try clickSidebarText(target)
            guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == target }, timeout: 4) else {
                throw Failure("clicking the \(target) header in the sidebar did not switch to it")
            }
            usleep(500_000)
            try check(target, how: "sidebar click")
        }

    }),
    ("workspace-switch-speed", "switching between two workspaces with windows of their own puts the other's window on screen within 300 ms (the system's window fade held it back by some 300 ms)", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        _ = try? d.exec("\(ctl) workspace switch Default")
        for ws in (try? d.workspaceList()) ?? [] {
            if let name = ws["name"] as? String, name.hasPrefix("E2ESpeed") { _ = try? d.exec("\(ctl) workspace delete \"\(name)\"") }
        }
        _ = try d.exec("\(ctl) workspace create E2ESpeed")
        defer {
            _ = try? d.exec("\(ctl) workspace switch Default")
            _ = try? d.exec("\(ctl) workspace delete E2ESpeed")
        }
        // The first switch to a workspace with no window opens one of its own.
        _ = try d.exec("\(ctl) workspace switch E2ESpeed")
        guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "E2ESpeed" }, timeout: 5) else {
            throw Failure("the switch to E2ESpeed never happened")
        }
        usleep(1_500_000)
        let speedWindows = d.onScreenWindowNumbers()
        _ = try d.exec("\(ctl) workspace switch Default")
        usleep(1_500_000)
        let defaultWindows = d.onScreenWindowNumbers()
        guard !speedWindows.isEmpty, !defaultWindows.isEmpty, speedWindows.isDisjoint(with: defaultWindows) else {
            throw Failure("the two workspaces do not show windows of their own: \(speedWindows) vs \(defaultWindows)")
        }
        var timings: [String] = []
        var slowest = 0.0
        for (i, target) in ["E2ESpeed", "Default", "E2ESpeed", "Default", "E2ESpeed", "Default"].enumerated() {
            let want = target == "E2ESpeed" ? speedWindows : defaultWindows
            let started = Date()
            _ = try d.exec("\(ctl) workspace switch \(target)")
            let answered = Date().timeIntervalSince(started)
            guard d.wait(for: { d.onScreenWindowNumbers() == want }, timeout: 5) else {
                throw Failure("switch \(i) to \(target): its window never came on screen alone (\(d.onScreenWindowNumbers()) vs \(want))")
            }
            let shown = Date().timeIntervalSince(started)
            slowest = max(slowest, shown)
            timings.append(String(format: "%@ answered %.0f ms, on screen %.0f ms", target, answered * 1000, shown * 1000))
            usleep(300_000)
        }
        // The same from the workspace pill at the top of the tab bar: click it,
        // click the workspace in its menu, as a hand does.
        for (i, target) in ["E2ESpeed", "Default", "E2ESpeed", "Default"].enumerated() {
            let want = target == "E2ESpeed" ? speedWindows : defaultWindows
            d.activate()
            try d.clickWorkspacePill(in: d.activeOnScreenWindow())
            guard d.wait(for: { d.openMenuItem(titled: target) != nil }, timeout: 3), let item = d.openMenuItem(titled: target),
                  let posValue: AXValue = d.attribute(item, kAXPositionAttribute),
                  let sizeValue: AXValue = d.attribute(item, kAXSizeAttribute) else {
                throw Failure("pill switch \(i): no \(target) in the workspace menu")
            }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &pos)
            AXValueGetValue(sizeValue, .cgSize, &size)
            let started = Date()
            try d.click(at: CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2))
            guard d.wait(for: { d.onScreenWindowNumbers() == want }, timeout: 5) else {
                throw Failure("pill switch \(i) to \(target): its window never came on screen alone")
            }
            let shown = Date().timeIntervalSince(started)
            slowest = max(slowest, shown)
            timings.append(String(format: "pill %@ on screen %.0f ms", target, shown * 1000))
            usleep(300_000)
        }
        // A second click on the pill closes its list and opens no new one.
        d.activate()
        try d.clickWorkspacePill(in: d.activeOnScreenWindow())
        guard d.wait(for: { d.openMenuItem(titled: "E2ESpeed") != nil }, timeout: 3) else {
            throw Failure("the workspace list did not open on the pill")
        }
        try d.clickWorkspacePill(in: d.activeOnScreenWindow())
        guard d.wait(for: { d.openMenuItem(titled: "E2ESpeed") == nil }, timeout: 2) else {
            throw Failure("a second click on the pill left the workspace list open")
        }
        usleep(400_000)
        guard d.openMenuItem(titled: "E2ESpeed") == nil else {
            throw Failure("a second click on the pill opened the workspace list again")
        }
        FileHandle.standardError.write(("[timing] workspace switch: " + timings.joined(separator: "; ") + "\n").data(using: .utf8)!)
        guard slowest < 0.3 else {
            throw Failure(String(format: "a workspace switch took %.0f ms to reach the screen: ", slowest * 1000) + timings.joined(separator: "; "))
        }
    }),
    ("broadcast", "takoctl broadcast starts and stops synchronized typing across panes with verified non-target execution barrier", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Record leader pane TTY and ID before splitting
        let leaderTtyPath = d.path("leader_tty.txt")
        d.activate()
        try d.run("tty > \(leaderTtyPath)")
        guard d.wait(for: { (try? d.file("leader_tty.txt").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false }, timeout: 5) else {
            throw Failure("failed to read initial leader pane TTY")
        }
        let leaderTty = try d.file("leader_tty.txt").trimmingCharacters(in: .whitespacesAndNewlines)

        func extractPanes(from json: String) -> [String] {
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let root = (obj["result"] as? [String: Any]) ?? obj
                if let windows = root["windows"] as? [[String: Any]] {
                    var ids: [String] = []
                    for w in windows {
                        for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                            for p in (t["panes"] as? [[String: Any]]) ?? [] {
                                if let id = p["id"] as? String { ids.append(id) }
                            }
                        }
                    }
                    if !ids.isEmpty { return ids }
                }
            }
            if let regex = try? NSRegularExpression(pattern: "\"id\"\\s*:\\s*\"([a-f0-9\\-]+)\"") {
                let nsStr = json as NSString
                let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsStr.length))
                return matches.map { nsStr.substring(with: $0.range(at: 1)) }
            }
            return []
        }
        let treeBefore = try d.exec("\(ctl) tree --json")
        let initialIds = extractPanes(from: treeBefore)
        guard let leaderId = initialIds.first else {
            throw Failure("could not identify initial leader pane ID from tree: \(treeBefore)")
        }

        let splitOutput = try d.exec("\(ctl) split right")
        let nonTargetId = splitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        usleep(600_000)

        // Refocus the leader pane so post-stop keyboard delivery is deterministically directed to leader
        _ = try d.exec("\(ctl) focus --target \(leaderId)")
        usleep(400_000)

        let witnessPath = d.path("bcast_witness.txt")
        _ = try d.exec("\(ctl) broadcast start")
        let status = try d.exec("\(ctl) broadcast status --json")
        guard status.contains("\"active\":true") || status.contains("\"active\": true") else {
            throw Failure("broadcast status was not active after start: \(status)")
        }
        // Send typing payload via keyboard while broadcast is active: record per-pane TTY identity
        d.activate()
        try d.run("tty >> \(witnessPath)")
        _ = try d.file("bcast_witness.txt")
        // Both panes must have received the keystrokes and written their distinct TTY path
        guard d.wait(for: {
            guard let content = try? String(contentsOfFile: witnessPath, encoding: .utf8) else { return false }
            let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let uniqueTtys = Set(lines)
            return lines.count == 2 && uniqueTtys.count == 2
        }, timeout: 5) else {
            let content = (try? String(contentsOfFile: witnessPath, encoding: .utf8)) ?? ""
            throw Failure("broadcast typing was not delivered to both distinct panes: \(content)")
        }
        // Stop broadcast
        _ = try d.exec("\(ctl) broadcast stop")
        let stopped = try d.exec("\(ctl) broadcast status --json")
        guard stopped.contains("\"active\":false") || stopped.contains("\"active\": false") else {
            throw Failure("broadcast was still active after stop: \(stopped)")
        }
        // Post-stop isolation: typing reaches focused leader pane
        let soloWitness = d.path("solo_witness.txt")
        d.activate()
        try d.run("tty >> \(soloWitness)")
        guard d.wait(for: {
            guard let content = try? String(contentsOfFile: soloWitness, encoding: .utf8) else { return false }
            let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.count == 1
        }, timeout: 5) else {
            let content = (try? String(contentsOfFile: soloWitness, encoding: .utf8)) ?? ""
            throw Failure("post-stop isolation failed: solo_witness occurrences != 1: \(content)")
        }

        // Ordered execution completion barrier through non-target pane's PTY queue with controlled delayed recipient
        let barrierFile = d.path("non_target_barrier.txt")
        _ = try d.exec("\(ctl) send \"sh -c 'sleep 0.2; echo non_target_barrier_done > \(barrierFile)'\" --target \(nonTargetId)")
        guard d.wait(for: {
            guard let text = try? String(contentsOfFile: barrierFile, encoding: .utf8) else { return false }
            return text.contains("non_target_barrier_done")
        }, timeout: 10) else {
            throw Failure("non-target execution barrier did not complete via PTY queue")
        }

        // Verify all witnesses: exactly one target TTY and zero non-target deliveries
        let finalContent = (try? String(contentsOfFile: soloWitness, encoding: .utf8)) ?? ""
        let finalLines = finalContent.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard finalLines.count == 1 && finalLines.first == leaderTty else {
            throw Failure("post-stop barrier check failed: expected exactly 1 leader delivery (\(leaderTty)), got: \(finalContent)")
        }
    }),
    ("input-ownership", "takoctl input lock and unlock control input ownership without error", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let leakFile = d.path("input_leak.txt")
        let autoFile = d.path("input_auto.txt")
        let recoveredFile = d.path("input_recovered.txt")

        _ = try d.exec("\(ctl) input lock --owner e2e-agent")
        let status = try d.exec("\(ctl) input status --json")
        guard (status.contains("\"locked\":true") || status.contains("\"locked\": true")) && status.contains("e2e-agent") else {
            throw Failure("input status was not locked to agent: \(status)")
        }

        // While locked, attempt physical human keyboard input: must be blocked by surface input gate
        d.activate()
        try d.run("echo 'leak_witness' > \(leakFile)")
        usleep(400_000)
        guard !FileManager.default.fileExists(atPath: leakFile) else {
            throw Failure("input lock failed: physical keyboard input leaked through while pane was locked")
        }

        // Verify approved automation command executes without error
        let autoStatus = try d.exec("\(ctl) input allow-automation")
        guard autoStatus.contains("allowed") || autoStatus.contains("true") else {
            throw Failure("allow-automation failed: \(autoStatus)")
        }

        // Send an authorized automated command and require its unique PTY witness during lock
        _ = try d.exec("\(ctl) send \"echo auto_witness > \(autoFile)\"")
        try d.expect("input_auto.txt", "auto_witness\n", "authorized automated input delivered while pane locked")

        // Unlock
        _ = try d.exec("\(ctl) input unlock")
        let unlocked = try d.exec("\(ctl) input status --json")
        guard unlocked.contains("\"locked\":false") || unlocked.contains("\"locked\": false") else {
            throw Failure("input status was still locked after unlock: \(unlocked)")
        }

        // Verify physical keyboard input recovery after unlock
        d.activate()
        try d.run("echo 'recovered_witness' > \(recoveredFile)")
        try d.expect("input_recovered.txt", "recovered_witness\n", "keyboard input recovery after unlock")
    }),
    ("diff-review", "takoctl review open, exercises file selection, comment add, Send Feedback UI button, exact PTY feedback, and clean dismissal", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Initialize git repo in a dedicated clean subdirectory of d.work with an uncommitted change to review
        let repoPath = d.path("diff_repo")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let initScript = """
        cd '\(repoPath)' && git init -b main && git config user.name 'Alex' && git config user.email 'alex@prod.codes' && \
        echo 'line 1' > review_test.txt && git add review_test.txt && git commit -m 'initial' && \
        echo 'line 2 added' >> review_test.txt
        """
        _ = try d.exec("sh -c \"\(initScript)\"")

        // Discover initial target pane ID before creating split
        let initialPanes = try d.paneIds()
        guard let targetPaneId = initialPanes.first else {
            throw Failure("could not identify initial target pane ID from tree")
        }

        // Create a non-target split pane to verify input isolation
        let splitOutput = try d.exec("\(ctl) split right")
        let nonTargetPaneId = splitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        usleep(400_000)

        // Refocus target pane and change directory to repoPath
        _ = try d.exec("\(ctl) focus --target \(targetPaneId)")
        usleep(300_000)
        d.activate()
        try d.run("cd '\(repoPath)'")
        usleep(300_000)

        // Allow automation on both panes so takoctl send is permitted
        _ = try d.exec("\(ctl) input allow-automation --target \(targetPaneId)")
        _ = try d.exec("\(ctl) input allow-automation --target \(nonTargetPaneId)")
        usleep(500_000)

        // Establish readiness of both capture processes with self-contained scripts
        let targetReady = d.path("target_ready.txt")
        let targetPreStart = "SENTINEL_TARGET_PRE_START_\(UUID().uuidString.prefix(6))"
        let targetPreStartAck = d.path("target_pre_start_ack.txt")
        let targetPreEnd = "SENTINEL_TARGET_PRE_END_\(UUID().uuidString.prefix(6))"
        let targetPreCaptured = d.path("target_pre_captured.txt")
        let targetPreEndAck = d.path("target_pre_end_ack.txt")
        let targetPost = "SENTINEL_TARGET_POST_\(UUID().uuidString.prefix(6))"
        let targetPostCaptured = d.path("target_post_captured.txt")
        let targetPostAck = d.path("target_post_ack.txt")

        let nonTargetReady = d.path("nontarget_ready.txt")
        let nonTargetPreStart = "SENTINEL_NONTARGET_PRE_START_\(UUID().uuidString.prefix(6))"
        let nonTargetPreStartAck = d.path("nontarget_pre_start_ack.txt")
        let nonTargetPreEnd = "SENTINEL_NONTARGET_PRE_END_\(UUID().uuidString.prefix(6))"
        let nonTargetPreCaptured = d.path("nontarget_pre_captured.txt")
        let nonTargetPreEndAck = d.path("nontarget_pre_end_ack.txt")
        let nonTargetPost = "SENTINEL_NONTARGET_POST_\(UUID().uuidString.prefix(6))"
        let nonTargetPostCaptured = d.path("nontarget_post_captured.txt")
        let nonTargetPostAck = d.path("nontarget_post_ack.txt")

        func makeCaptureScript(ready: String, preStart: String, preStartAck: String, preEnd: String, preCaptured: String, preEndAck: String, post: String, postCaptured: String, postAck: String) -> String {
            """
            #!/usr/bin/env python3
            import sys

            ready_file = "\(ready)"
            pre_start_sentinel = "\(preStart)"
            pre_start_ack_file = "\(preStartAck)"
            pre_end_sentinel = "\(preEnd)"
            pre_captured_file = "\(preCaptured)"
            pre_end_ack_file = "\(preEndAck)"
            post_sentinel = "\(post)"
            post_captured_file = "\(postCaptured)"
            post_ack_file = "\(postAck)"

            with open(ready_file, "w") as f:
                f.write("ready\\n")
                f.flush()

            state = 0
            pre_captured = []
            post_captured = []

            while True:
                line = sys.stdin.readline()
                if not line:
                    break
                if state == 0:
                    if pre_start_sentinel in line:
                        idx = line.find(pre_start_sentinel)
                        prefix = line[:idx]
                        suffix = line[idx + len(pre_start_sentinel):]
                        if prefix or suffix not in ("", "\\n", "\\r\\n", "\\r"):
                            with open(pre_start_ack_file, "w") as f:
                                f.write("pre_start_corrupted:" + prefix + suffix + "\\n")
                                f.flush()
                            sys.exit(1)
                        with open(pre_start_ack_file, "w") as f:
                            f.write("pre_start_ack\\n")
                            f.flush()
                        state = 1
                elif state == 1:
                    if pre_end_sentinel in line:
                        idx = line.find(pre_end_sentinel)
                        prefix = line[:idx]
                        suffix = line[idx + len(pre_end_sentinel):]
                        if prefix:
                            pre_captured.append(prefix)
                        if suffix not in ("", "\\n", "\\r\\n", "\\r"):
                            pre_captured.append(suffix)
                        with open(pre_captured_file, "w") as f:
                            f.write("".join(pre_captured))
                            f.flush()
                        with open(pre_end_ack_file, "w") as f:
                            f.write("pre_end_ack\\n")
                            f.flush()
                        state = 2
                    else:
                        pre_captured.append(line)
                elif state == 2:
                    if post_sentinel in line:
                        idx = line.find(post_sentinel)
                        prefix = line[:idx]
                        suffix = line[idx + len(post_sentinel):]
                        if prefix:
                            post_captured.append(prefix)
                        if suffix not in ("", "\\n", "\\r\\n", "\\r"):
                            post_captured.append(suffix)
                        with open(post_captured_file, "w") as f:
                            f.write("".join(post_captured))
                            f.flush()
                        with open(post_ack_file, "w") as f:
                            f.write("post_ack\\n")
                            f.flush()
                        sys.exit(0)
                    else:
                        post_captured.append(line)
            """
        }

        let targetScript = d.path("target_capture.py")
        try makeCaptureScript(
            ready: targetReady, preStart: targetPreStart, preStartAck: targetPreStartAck,
            preEnd: targetPreEnd, preCaptured: targetPreCaptured, preEndAck: targetPreEndAck,
            post: targetPost, postCaptured: targetPostCaptured, postAck: targetPostAck
        ).write(toFile: targetScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetScript)

        let nonTargetScript = d.path("nontarget_capture.py")
        try makeCaptureScript(
            ready: nonTargetReady, preStart: nonTargetPreStart, preStartAck: nonTargetPreStartAck,
            preEnd: nonTargetPreEnd, preCaptured: nonTargetPreCaptured, preEndAck: nonTargetPreEndAck,
            post: nonTargetPost, postCaptured: nonTargetPostCaptured, postAck: nonTargetPostAck
        ).write(toFile: nonTargetScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonTargetScript)

        // Start capture processes in both panes
        _ = try d.exec("\(ctl) send '\(targetScript)' --target \(targetPaneId)")
        _ = try d.exec("\(ctl) send '\(nonTargetScript)' --target \(nonTargetPaneId)")

        guard d.wait(for: {
            FileManager.default.fileExists(atPath: targetReady) && FileManager.default.fileExists(atPath: nonTargetReady)
        }, timeout: 8) else {
            throw Failure("stream capture processes did not become ready in both target and non-target panes")
        }

        // Send pre-start sentinels to both panes to begin capturing the pre-send interval
        _ = try d.exec("\(ctl) send '\(targetPreStart)' --target \(targetPaneId)")
        _ = try d.exec("\(ctl) send '\(nonTargetPreStart)' --target \(nonTargetPaneId)")
        guard d.wait(for: {
            guard let tAck = try? String(contentsOfFile: targetPreStartAck, encoding: .utf8),
                  let ntAck = try? String(contentsOfFile: nonTargetPreStartAck, encoding: .utf8) else { return false }
            return tAck == "pre_start_ack\n" && ntAck == "pre_start_ack\n"
        }, timeout: 8) else {
            throw Failure("stream capture processes did not acknowledge pre-start sentinels with exact framing")
        }

        // Open diff review session targeting targetPaneId
        _ = try d.exec("\(ctl) review open \"\(repoPath)\" --target-pane \(targetPaneId)")
        let status = try d.exec("\(ctl) review status --json")
        guard (status.contains("\"open\":true") || status.contains("\"open\": true")) &&
              (status.contains("\"files_count\":1") || status.contains("\"files_count\": 1") || (status.contains("\"files_count\":") && !status.contains("\"files_count\":0"))) else {
            throw Failure("review status did not reflect active session with changed file: \(status)")
        }

        // Verify on-screen presentation of Diff Review pane
        guard d.wait(for: { d.hasText(containing: "DIFF REVIEW") }, timeout: 5) else {
            throw Failure("Diff Review visual header was not presented on screen")
        }

        // Require file row in sidebar (mandatory UI interaction)
        guard let fileBtn = d.button(titled: "review_test.txt") ?? d.button(titled: "DiffFileRow_review_test.txt") else {
            throw Failure("review_test.txt file row not found in Diff Review sidebar")
        }
        d.press(fileBtn)
        usleep(200_000)

        // Require Add comment button for line 2 (mandatory UI interaction)
        guard let addCommentBtn = d.button(titled: "AddCommentButton_Line2") else {
            throw Failure("AddCommentButton_Line2 not found for line 2")
        }
        d.press(addCommentBtn)
        usleep(300_000)

        // Require composer controls: text field and submit button
        guard let commentField = d.textField(identifier: "CommentTextField_Line2") else {
            let tfs = d.textFields()
            throw Failure("CommentTextField_Line2 composer not found after clicking Add. TextFields: \(tfs)")
        }
        guard let submitCommentBtn = d.button(titled: "SubmitCommentButton_Line2") else {
            throw Failure("SubmitCommentButton_Line2 not found in composer")
        }

        // Focus text field and type unique comment via real keyboard events
        let uniqueComment = "E2E unique review comment on line 2"
        d.activate()
        _ = AXUIElementSetAttributeValue(commentField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(150_000)
        try d.type(uniqueComment)
        usleep(200_000)

        // Submit comment via UI button (one submission)
        d.press(submitCommentBtn)
        usleep(300_000)

        // Verify via independent read-only CLI witness that UI submission created the comment (NO CLI fallback mutation!)
        let verifiedComments = try d.exec("\(ctl) review comment list --json")
        guard verifiedComments.contains(uniqueComment) && (verifiedComments.contains("\"line\":2") || verifiedComments.contains("\"line\": 2")) && verifiedComments.contains("review_test.txt") else {
            throw Failure("review comment list did not contain UI-added comment '\(uniqueComment)': \(verifiedComments)")
        }

        // Ordered execution completion barrier through each pane's own PTY stream before Send
        _ = try d.exec("\(ctl) send '\(targetPreEnd)' --target \(targetPaneId)")
        _ = try d.exec("\(ctl) send '\(nonTargetPreEnd)' --target \(nonTargetPaneId)")
        guard d.wait(for: {
            guard let tAck = try? String(contentsOfFile: targetPreEndAck, encoding: .utf8),
                  let ntAck = try? String(contentsOfFile: nonTargetPreEndAck, encoding: .utf8) else { return false }
            return tAck == "pre_end_ack\n" && ntAck == "pre_end_ack\n"
        }, timeout: 8) else {
            throw Failure("stream capture processes did not acknowledge pre-end sentinels with exact framing")
        }

        // Assert zero feedback was prematurely dispatched to target PTY and zero input leaked to non-target PTY
        guard FileManager.default.fileExists(atPath: targetPreCaptured),
              let targetPreContent = try? String(contentsOfFile: targetPreCaptured, encoding: .utf8) else {
            throw Failure("target pre-send capture file is missing or unreadable: \(targetPreCaptured)")
        }
        guard targetPreContent.isEmpty else {
            throw Failure("feedback was prematurely dispatched to target PTY before Send button was clicked (got \(targetPreContent.count) bytes: \(targetPreContent.debugDescription))")
        }

        guard FileManager.default.fileExists(atPath: nonTargetPreCaptured),
              let nonTargetPreContent = try? String(contentsOfFile: nonTargetPreCaptured, encoding: .utf8) else {
            throw Failure("non-target pre-send capture file is missing or unreadable: \(nonTargetPreCaptured)")
        }
        guard nonTargetPreContent.isEmpty else {
            throw Failure("premature input leaked to non-target PTY before Send button was clicked (got \(nonTargetPreContent.count) bytes: \(nonTargetPreContent.debugDescription))")
        }

        // Locate Send Feedback UI button ("Send Feedback (1)")
        var sendBtn: AXUIElement?
        guard d.wait(for: {
            guard let btn = d.button(titled: "Send Feedback (1)") ?? d.button(titled: "SendFeedbackButton") else { return false }
            let enabled: Bool? = d.attribute(btn, kAXEnabledAttribute)
            if enabled == true || enabled == nil {
                sendBtn = btn
                return true
            }
            return false
        }, timeout: 6), let sendBtn else {
            let allBtns = d.windows().first.map { d.descendants(of: $0, role: kAXButtonRole as String).compactMap { d.attribute($0, kAXTitleAttribute) as String? ?? d.attribute($0, "AXLabel") as String? ?? d.attribute($0, "AXIdentifier") as String? } } ?? []
            throw Failure("Send Feedback (1) UI button not found or not enabled on screen. Buttons: \(allBtns)")
        }

        // Press Send ONCE (do not repress inside wait)
        d.press(sendBtn)
        usleep(300_000)

        // Require ordered post-send sentinel acknowledgment through each observed pane's own input stream
        _ = try d.exec("\(ctl) send '\(targetPost)' --target \(targetPaneId)")
        _ = try d.exec("\(ctl) send '\(nonTargetPost)' --target \(nonTargetPaneId)")
        guard d.wait(for: {
            guard let tAck = try? String(contentsOfFile: targetPostAck, encoding: .utf8),
                  let ntAck = try? String(contentsOfFile: nonTargetPostAck, encoding: .utf8) else { return false }
            return tAck == "post_ack\n" && ntAck == "post_ack\n"
        }, timeout: 10) else {
            throw Failure("stream capture processes did not acknowledge post sentinels with exact framing")
        }

        // Compare complete expected feedback message to verify exact-once delivery in target pane
        guard FileManager.default.fileExists(atPath: targetPostCaptured),
              let rawTargetFeedback = try? String(contentsOfFile: targetPostCaptured, encoding: .utf8) else {
            throw Failure("target post-send capture file is missing or unreadable: \(targetPostCaptured)")
        }
        let expectedHeader = "Review feedback for worktree 'diff_repo' (base: main):"
        let expectedFile = "## review_test.txt"
        let expectedLine = "• Line 2: \(uniqueComment)"
        let expectedMessage = "\(expectedHeader)\n\n\(expectedFile)\n\(expectedLine)\n"
        guard rawTargetFeedback == expectedMessage else {
            throw Failure("feedback message did not match expected exact-once format.\nExpected:\n\(expectedMessage.debugDescription)\n\nGot:\n\(rawTargetFeedback.debugDescription)")
        }

        // Verify non-target pane received zero feedback bytes
        guard FileManager.default.fileExists(atPath: nonTargetPostCaptured),
              let rawNonTargetFeedback = try? String(contentsOfFile: nonTargetPostCaptured, encoding: .utf8) else {
            throw Failure("non-target post-send capture file is missing or unreadable: \(nonTargetPostCaptured)")
        }
        guard rawNonTargetFeedback.isEmpty else {
            throw Failure("non-target pane received feedback intended exclusively for target pane (got \(rawNonTargetFeedback.count) bytes: \(rawNonTargetFeedback.debugDescription))")
        }

        // Dismiss review session via Close button (or Escape)
        if let closeBtn = d.button(titled: "ReviewCloseButton") {
            d.press(closeBtn)
        } else {
            d.key(Key.escape)
        }
        guard d.wait(for: { !d.hasText(containing: "DIFF REVIEW") }, timeout: 5) else {
            throw Failure("Close button/Escape did not dismiss Diff Review overlay")
        }
        let closedStatus = try d.exec("\(ctl) review status --json")
        guard closedStatus.contains("\"open\":false") || closedStatus.contains("\"open\": false") else {
            throw Failure("review was still open after dismissal: \(closedStatus)")
        }

        // Assert that dismissal returned focus to the target pane without any CLI or AX focus repair
        guard let focusedId = try d.focusedPaneId() else {
            throw Failure("could not determine focused pane ID after review dismissal")
        }
        guard focusedId.lowercased() == targetPaneId.lowercased() else {
            throw Failure("review dismissal left focus on pane '\(focusedId)', expected target pane '\(targetPaneId)'")
        }

        // Verify unassisted terminal keyboard input recovery
        d.activate()
        try d.run("echo 'review_ok' > \(d.path("review_witness"))")
        try d.expect("review_witness", "review_ok\n", "terminal keyboard input after review session closed")
    }),
    ("overlay", "takoctl overlay opens markdown document with verified on-screen metadata, renders document body fixture, and closes cleanly", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Create document inside d.work (run-owned temporary workspace)
        let docPath = d.path("tako_overlay_test.md")
        try "# Test Note\nHello Sandboxed Overlay Content\n".write(toFile: docPath, atomically: true, encoding: .utf8)

        // Move the pane cwd into d.work and verify cwd updated
        d.activate()
        try d.run("cd '\(d.work.path)' && pwd > \(d.path("overlay_cwd.txt"))")
        guard d.wait(for: {
            let current = (try? d.file("overlay_cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            return current == d.work.path
        }, timeout: 5) else {
            throw Failure("failed to change pane cwd to owned temporary directory \(d.work.path)")
        }

        let openRes = try d.exec("\(ctl) overlay open \"\(docPath)\"")
        let status = try d.exec("\(ctl) overlay status --json")
        guard (status.contains("\"open\":true") || status.contains("\"open\": true")) &&
              status.contains("tako_overlay_test.md") &&
              status.contains("markdown") else {
            throw Failure("overlay status did not return open markdown document (open result: \(openRes)): \(status)")
        }

        // Verify on-screen overlay presentation and sandboxed indicator
        guard d.wait(for: { d.hasText(containing: "MARKDOWN") && d.hasText(containing: "sandboxed:") }, timeout: 5) else {
            throw Failure("overlay visual header bar or sandboxed indicator not found on screen")
        }

        // Verify actual document body content rendered inside overlay
        guard d.wait(for: { d.hasText(containing: "Hello Sandboxed Overlay Content") || d.hasText(containing: "Test Note") }, timeout: 6) else {
            throw Failure("overlay body content 'Hello Sandboxed Overlay Content' was not rendered on screen")
        }

        // Dismiss overlay via Escape
        d.key(Key.escape)
        guard d.wait(for: { !d.hasText(containing: "MARKDOWN") }, timeout: 5) else {
            throw Failure("Escape did not dismiss overlay")
        }

        let closed = try d.exec("\(ctl) overlay status --json")
        guard closed.contains("\"open\":false") || closed.contains("\"open\": false") else {
            throw Failure("overlay was still open after Escape: \(closed)")
        }

        // Verify unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'overlay_ok' > \(d.path("overlay_witness"))")
        try d.expect("overlay_witness", "overlay_ok\n", "terminal keyboard input after overlay closed")
    }),
    ("overlay-form", "a form in an overlay answers takoctl overlay open --wait: typed text, a checkbox and the pressed button come back as name=value lines; closing it unsent fails the wait", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let form = d.path("tako_form.html")
        try """
        <h1>Deploy?</h1>
        <form action="tako-submit:">
          <input name="who" aria-label="Who">
          <label><input type="checkbox" name="tags" value="court" checked> court</label>
          <label><input type="checkbox" name="tags" value="urgent"> urgent</label>
          <button name="action" value="reject">Reject</button>
          <button name="action" value="approve">Approve</button>
        </form>
        """.write(toFile: form, atomically: true, encoding: .utf8)
        d.activate()
        try d.run("cd '\(d.work.path)' && pwd > \(d.path("form_cwd.txt"))")
        guard d.wait(for: { ((try? d.file("form_cwd.txt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == d.work.path },
                     timeout: 5) else { throw Failure("the pane did not move into the run's directory") }

        // takoctl waits in the background; its output and exit code land in files.
        func waitInBackground(_ tag: String) throws {
            _ = try d.exec("( \(ctl) overlay open \"\(form)\" --wait --timeout 60 > \(d.path("\(tag).out")) 2>&1; "
                + "echo $? > \(d.path("\(tag).code")) ) > /dev/null 2>&1 &")
        }
        try waitInBackground("submitted")
        guard d.wait(for: { d.button(titled: "Approve") != nil }, timeout: 8) else {
            throw Failure("the form's Approve button never showed in the overlay")
        }
        // A person's way through it: click the field, type, tick a box, press Approve.
        guard let field = d.onScreenWindows().flatMap({ d.descendants(of: $0, role: kAXTextFieldRole as String) })
            .first(where: { ((d.attribute($0, kAXDescriptionAttribute) as String?) ?? (d.attribute($0, kAXTitleAttribute) as String?) ?? "").contains("Who") })
            ?? d.onScreenWindows().flatMap({ d.descendants(of: $0, role: kAXTextFieldRole as String) }).first else {
            throw Failure("no text field in the overlay's form")
        }
        try d.clickElement(field)
        usleep(200_000)
        try d.type("Alex")
        if let urgent = d.onScreenWindows().flatMap({ d.descendants(of: $0, role: kAXCheckBoxRole as String) })
            .first(where: { ((d.attribute($0, kAXTitleAttribute) as String?) ?? (d.attribute($0, kAXDescriptionAttribute) as String?) ?? "").contains("urgent") }) {
            try d.clickElement(urgent)
            usleep(150_000)
        }
        try d.clickButton(titled: "Approve")
        let code = try d.file("submitted.code", timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = try d.file("submitted.out")
        guard code == "0" else { throw Failure("overlay open --wait exited \(code): \(out)") }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.first == "who=Alex", lines.contains("tags=court"), lines.last == "action=approve" else {
            throw Failure("the form's answer is not what was typed and pressed: \(lines)")
        }
        guard d.wait(for: { !d.hasText(containing: "Deploy?") }, timeout: 5) else {
            throw Failure("the overlay stayed open after its form was submitted")
        }

        // Closed unsent: the wait fails, and says so.
        try waitInBackground("closed")
        guard d.wait(for: { d.button(titled: "Approve") != nil }, timeout: 8) else {
            throw Failure("the form did not open a second time")
        }
        d.activate()
        d.key(Key.escape)
        let closedCode = try d.file("closed.code", timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        let closedOut = try d.file("closed.out")
        guard closedCode != "0", closedOut.contains("closed without a submission") else {
            throw Failure("closing the overlay unsent did not fail the wait (exit \(closedCode)): \(closedOut)")
        }
        try d.run("echo 'form_ok' > \(d.path("form_witness"))")
        try d.expect("form_witness", "form_ok\n", "terminal keyboard input after the form overlay")
    }),
    ("ask-prompt", "takoctl ask opens interactive modal dialogs for confirmation, choices, and text input, returning structured answers with unassisted focus recovery", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl"
        let witness = d.path("ask_witness")

        func waitForProcess(_ proc: Process, pipe: Pipe, timeout: TimeInterval = 6) throws -> (status: Int32, data: Data) {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                proc.terminate()
                usleep(100_000)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                throw Failure("child process failed to finish within \(timeout)s deadline")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (proc.terminationStatus, data)
        }

        // Phase 1: Test interactive cancellation path (Abort button)
        let abortProc = Process()
        abortProc.executableURL = URL(fileURLWithPath: ctl)
        abortProc.arguments = [
            "--bundle-id", d.bundleID,
            "ask", "Discard uncommitted changes?",
            "--confirm",
            "--confirm-text", "Discard",
            "--cancel-text", "Abort",
            "--title", "Agent Prompt",
            "--timeout", "8s",
            "--json"
        ]
        let abortPipe = Pipe()
        abortProc.standardOutput = abortPipe
        abortProc.standardError = abortPipe
        try abortProc.run()
        defer {
            if abortProc.isRunning {
                abortProc.terminate()
                usleep(50_000)
                if abortProc.isRunning { kill(abortProc.processIdentifier, SIGKILL) }
            }
        }

        var abortBtn: AXUIElement?
        guard d.wait(for: {
            abortBtn = d.button(titled: "Abort")
            return abortBtn != nil && d.button(titled: "Discard") != nil
        }, timeout: 5), let abortBtn else {
            throw Failure("takoctl ask did not present dialog with Abort and Discard buttons")
        }

        guard d.hasText(containing: "Agent Prompt") || d.hasText(containing: "Discard uncommitted changes?") else {
            throw Failure("prompt dialog does not expose title or message to accessibility")
        }

        // Click Abort to cancel
        d.press(abortBtn)
        guard d.wait(for: { d.button(titled: "Abort") == nil }, timeout: 5) else {
            throw Failure("prompt dialog was not dismissed after pressing Abort")
        }

        let (abortStatus, abortData) = try waitForProcess(abortProc, pipe: abortPipe, timeout: 6)
        guard abortStatus != 0 else {
            throw Failure("takoctl ask should exit with error when prompt is aborted, got 0")
        }
        guard let abortJson = try? JSONSerialization.jsonObject(with: abortData) as? [String: Any] else {
            throw Failure("expected valid JSON output on abort, got \(String(data: abortData, encoding: .utf8) ?? "")")
        }
        guard abortJson["ok"] as? Bool == false else {
            throw Failure("expected ok: false on aborted prompt, got \(abortJson)")
        }
        guard let errDict = abortJson["error"] as? [String: Any],
              errDict["code"] as? String == "invalid",
              let errMsg = errDict["message"] as? String,
              errMsg.contains("cancelled") else {
            throw Failure("expected error.code == 'invalid' and error.message containing 'cancelled', got \(abortJson)")
        }

        // Phase 2: Test interactive confirmation path (Deploy button)
        let confirmProc = Process()
        confirmProc.executableURL = URL(fileURLWithPath: ctl)
        confirmProc.arguments = [
            "--bundle-id", d.bundleID,
            "ask", "Deploy changes to production?",
            "--confirm",
            "--confirm-text", "Deploy",
            "--cancel-text", "Cancel",
            "--title", "Deployment Confirmation",
            "--timeout", "8s",
            "--json"
        ]
        let confirmPipe = Pipe()
        confirmProc.standardOutput = confirmPipe
        confirmProc.standardError = confirmPipe
        try confirmProc.run()
        defer {
            if confirmProc.isRunning {
                confirmProc.terminate()
                usleep(50_000)
                if confirmProc.isRunning { kill(confirmProc.processIdentifier, SIGKILL) }
            }
        }

        var deployBtn: AXUIElement?
        guard d.wait(for: {
            deployBtn = d.button(titled: "Deploy")
            return deployBtn != nil && d.button(titled: "Cancel") != nil
        }, timeout: 5), let deployBtn else {
            throw Failure("takoctl ask did not present dialog with Deploy and Cancel buttons")
        }

        guard d.hasText(containing: "Deployment Confirmation") || d.hasText(containing: "Deploy changes to production?") else {
            throw Failure("prompt dialog does not expose confirmation title or message to accessibility")
        }

        // Click Deploy to confirm
        d.press(deployBtn)
        guard d.wait(for: { d.button(titled: "Deploy") == nil }, timeout: 5) else {
            throw Failure("prompt dialog was not dismissed after pressing Deploy")
        }

        let (confirmStatus, confirmData) = try waitForProcess(confirmProc, pipe: confirmPipe, timeout: 6)
        guard confirmStatus == 0 else {
            let errText = String(data: confirmData, encoding: .utf8) ?? ""
            throw Failure("takoctl ask confirm exited with code \(confirmStatus): \(errText)")
        }

        guard let confirmJson = try? JSONSerialization.jsonObject(with: confirmData) as? [String: Any],
              confirmJson["ok"] as? Bool == true,
              let confirmResult = confirmJson["result"] as? [String: Any] else {
            throw Failure("invalid JSON response from takoctl ask: \(String(data: confirmData, encoding: .utf8) ?? "")")
        }
        guard confirmResult["confirmed"] as? Bool == true else {
            throw Failure("expected result.confirmed == true, got \(confirmResult)")
        }
        guard confirmResult["answer"] as? String == "Deploy" else {
            throw Failure("expected result.answer == 'Deploy', got \(confirmResult)")
        }
        guard confirmResult["type"] as? String == "confirm" else {
            throw Failure("expected result.type == 'confirm', got \(confirmResult)")
        }

        // Phase 3: Test choice selection path (Production choice)
        let choiceProc = Process()
        choiceProc.executableURL = URL(fileURLWithPath: ctl)
        choiceProc.arguments = [
            "--bundle-id", d.bundleID,
            "ask", "Select deployment target:",
            "--choices", "Staging,Production,Canary",
            "--title", "Target Selection",
            "--timeout", "8s",
            "--json"
        ]
        let choicePipe = Pipe()
        choiceProc.standardOutput = choicePipe
        choiceProc.standardError = choicePipe
        try choiceProc.run()
        defer {
            if choiceProc.isRunning {
                choiceProc.terminate()
                usleep(50_000)
                if choiceProc.isRunning { kill(choiceProc.processIdentifier, SIGKILL) }
            }
        }

        var prodBtn: AXUIElement?
        guard d.wait(for: {
            prodBtn = d.button(titled: "Production")
            return prodBtn != nil && d.button(titled: "Staging") != nil && d.button(titled: "Canary") != nil
        }, timeout: 5), let prodBtn else {
            throw Failure("takoctl ask did not present choice dialog with Staging, Production, and Canary buttons")
        }

        guard d.hasText(containing: "Target Selection") || d.hasText(containing: "Select deployment target:") else {
            throw Failure("choice dialog does not expose title or message to accessibility")
        }

        // Click Production to select
        d.press(prodBtn)
        guard d.wait(for: { d.button(titled: "Production") == nil }, timeout: 5) else {
            throw Failure("choice dialog was not dismissed after pressing Production")
        }

        let (choiceStatus, choiceData) = try waitForProcess(choiceProc, pipe: choicePipe, timeout: 6)
        guard choiceStatus == 0 else {
            let errText = String(data: choiceData, encoding: .utf8) ?? ""
            throw Failure("takoctl ask choices exited with code \(choiceStatus): \(errText)")
        }

        guard let choiceJson = try? JSONSerialization.jsonObject(with: choiceData) as? [String: Any],
              choiceJson["ok"] as? Bool == true,
              let choiceResult = choiceJson["result"] as? [String: Any] else {
            throw Failure("invalid JSON response from takoctl ask choice: \(String(data: choiceData, encoding: .utf8) ?? "")")
        }
        guard choiceResult["type"] as? String == "choice" else {
            throw Failure("expected result.type == 'choice', got \(choiceResult)")
        }
        guard choiceResult["answer"] as? String == "Production" else {
            throw Failure("expected result.answer == 'Production', got \(choiceResult)")
        }
        guard choiceResult["choice"] as? String == "Production" else {
            throw Failure("expected result.choice == 'Production', got \(choiceResult)")
        }
        guard let choiceIndex = (choiceResult["index"] as? NSNumber)?.intValue, choiceIndex == 1 else {
            throw Failure("expected result.index == 1, got \(choiceResult)")
        }

        // Phase 4: Test free-text input path (typing v2.4.1 and Submit)
        let textProc = Process()
        textProc.executableURL = URL(fileURLWithPath: ctl)
        textProc.arguments = [
            "--bundle-id", d.bundleID,
            "ask", "Enter release tag:",
            "--placeholder", "v0.0.0",
            "--title", "Release Configuration",
            "--timeout", "8s",
            "--json"
        ]
        let textPipe = Pipe()
        textProc.standardOutput = textPipe
        textProc.standardError = textPipe
        try textProc.run()
        defer {
            if textProc.isRunning {
                textProc.terminate()
                usleep(50_000)
                if textProc.isRunning { kill(textProc.processIdentifier, SIGKILL) }
            }
        }

        var submitBtn: AXUIElement?
        guard d.wait(for: {
            submitBtn = d.button(titled: "Submit")
            return submitBtn != nil && d.button(titled: "Cancel") != nil
        }, timeout: 5), let submitBtn else {
            throw Failure("takoctl ask did not present text input dialog with Submit and Cancel buttons")
        }

        guard d.hasText(containing: "Release Configuration") || d.hasText(containing: "Enter release tag:") else {
            throw Failure("text prompt dialog does not expose title or message to accessibility")
        }

        // Type release tag into active text field
        d.activate()
        usleep(100_000)
        try d.type("v2.4.1")
        usleep(100_000)

        // Click Submit to confirm
        d.press(submitBtn)
        guard d.wait(for: { d.button(titled: "Submit") == nil }, timeout: 5) else {
            throw Failure("text input dialog was not dismissed after pressing Submit")
        }

        let (textStatus, textData) = try waitForProcess(textProc, pipe: textPipe, timeout: 6)
        guard textStatus == 0 else {
            let errText = String(data: textData, encoding: .utf8) ?? ""
            throw Failure("takoctl ask text exited with code \(textStatus): \(errText)")
        }

        guard let textJson = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
              textJson["ok"] as? Bool == true,
              let textResult = textJson["result"] as? [String: Any] else {
            throw Failure("invalid JSON response from takoctl ask text: \(String(data: textData, encoding: .utf8) ?? "")")
        }
        guard textResult["type"] as? String == "text" else {
            throw Failure("expected result.type == 'text', got \(textResult)")
        }
        guard textResult["answer"] as? String == "v2.4.1" else {
            throw Failure("expected result.answer == 'v2.4.1', got \(textResult)")
        }

        // Phase 5: Verify unassisted terminal keyboard input recovery
        d.activate()
        try d.run("echo 'ask_all_ok' > \(witness)")
        try d.expect("ask_witness", "ask_all_ok\n", "terminal keyboard input after prompt modal interaction")
    }),
    ("subagent-close", "takoctl split --child-of creates subagent hierarchy, Cmd+W prompts confirmation for closing parent and subagents, Cancel preserves panes, Close recursively closes hierarchy, and terminal retains focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let witness = d.path("subagent_witness")

        // Step 1: Open a new tab (Tab 2) so closing the subagent hierarchy does not close the whole window
        guard let tab1PaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover root pane ID in tab 1")
        }
        try d.run("tty > \(d.path("subagent_tab1_tty"))")
        let rootTty = try d.file("subagent_tab1_tty").trimmingCharacters(in: .whitespacesAndNewlines)

        d.key(Key.t, .maskCommand)
        usleep(1_200_000)

        try d.run("tty > \(d.path("subagent_tab2_tty"))")
        let parentTty = try d.file("subagent_tab2_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard rootTty != parentTty else {
            throw Failure("Cmd+T did not switch focus to newly created tab")
        }

        // Discover focused parent pane ID in Tab 2
        guard let parentId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused parent pane ID in tab 2")
        }
        guard parentId != tab1PaneId else {
            throw Failure("tab 2 parent pane ID equals tab 1 pane ID")
        }

        // Step 2: Split to create child subagent 1 under parent
        _ = try d.exec("\(ctl) split --target \(parentId) --child-of \(parentId) --label worker-1 --json")
        usleep(800_000)

        // Verify child 1 in tree
        let tree1Json = try d.exec("\(ctl) tree --json")
        guard let tree1Data = tree1Json.data(using: .utf8),
              let tree1Obj = try? JSONSerialization.jsonObject(with: tree1Data) as? [String: Any],
              let tree1Result = (tree1Obj["result"] as? [String: Any]) ?? Optional(tree1Obj),
              let windows1 = tree1Result["windows"] as? [[String: Any]] else {
            throw Failure("failed to parse tree JSON after first split: \(tree1Json)")
        }

        var child1Id: String?
        for w in windows1 {
            for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                for p in (t["panes"] as? [[String: Any]]) ?? [] {
                    if p["parent"] as? String == parentId {
                        child1Id = p["id"] as? String
                    }
                }
            }
        }
        guard let child1Id, !child1Id.isEmpty else {
            throw Failure("tree does not show child subagent with parent \(parentId): \(tree1Json)")
        }

        // Step 3: Split child 1 to create grandChild (recursive subagent hierarchy)
        _ = try d.exec("\(ctl) split --target \(child1Id) --child-of \(child1Id) --label grandchild-worker --json")
        usleep(800_000)

        // Verify recursive subagent in tree
        let tree2Json = try d.exec("\(ctl) tree --json")
        guard let tree2Data = tree2Json.data(using: .utf8),
              let tree2Obj = try? JSONSerialization.jsonObject(with: tree2Data) as? [String: Any],
              let tree2Result = (tree2Obj["result"] as? [String: Any]) ?? Optional(tree2Obj),
              let windows2 = tree2Result["windows"] as? [[String: Any]] else {
            throw Failure("failed to parse tree JSON after second split: \(tree2Json)")
        }

        var grandChildId: String?
        for w in windows2 {
            for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                for p in (t["panes"] as? [[String: Any]]) ?? [] {
                    if p["parent"] as? String == child1Id {
                        grandChildId = p["id"] as? String
                    }
                }
            }
        }
        guard let grandChildId, !grandChildId.isEmpty else {
            throw Failure("tree does not show grandchild subagent with parent \(child1Id): \(tree2Json)")
        }

        // Step 4: Test hierarchy collapse and expand
        _ = try d.exec("\(ctl) collapse \(parentId)")
        let collapseTree = try d.exec("\(ctl) tree --json")
        guard collapseTree.contains("\"collapsed\":true") || collapseTree.contains("\"collapsed\": true") else {
            throw Failure("tree does not reflect collapsed parent state: \(collapseTree)")
        }

        _ = try d.exec("\(ctl) expand \(parentId)")
        let expandTree = try d.exec("\(ctl) tree --json")
        guard expandTree.contains("\"collapsed\":false") || expandTree.contains("\"collapsed\": false") else {
            throw Failure("tree does not reflect expanded parent state: \(expandTree)")
        }

        // Step 5: Focus parent pane and trigger close via Cmd+W
        _ = try d.exec("\(ctl) focus --target \(parentId)")
        usleep(400_000)
        d.activate()
        usleep(200_000)

        d.key(Key.w, .maskCommand)

        // Step 6: Verify confirmation modal presentation and accessible text
        var cancelBtn: AXUIElement?
        var closeBtn: AXUIElement?
        guard d.wait(for: {
            cancelBtn = d.button(titled: "Cancel")
            closeBtn = d.button(titled: "Close")
            return cancelBtn != nil && closeBtn != nil
        }, timeout: 5), let cancelBtn else {
            throw Failure("Cmd+W on parent pane with subagents did not present confirmation dialog")
        }

        guard d.hasText(containing: "Close Parent Pane and Subagents?") &&
              (d.hasText(containing: "child subagent") || d.hasText(containing: "Closing it will also close its child panes")) else {
            throw Failure("subagent close dialog does not expose title or warning text to accessibility")
        }

        // Step 7: Test Cancel path
        d.press(cancelBtn)
        guard d.wait(for: { d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("subagent close dialog was not dismissed after Cancel")
        }

        // Verify in tree that neither parent nor children were removed
        let treeAfterCancel = try d.exec("\(ctl) tree --json")
        guard treeAfterCancel.contains(parentId) &&
              treeAfterCancel.contains(child1Id) &&
              treeAfterCancel.contains(grandChildId) else {
            throw Failure("Cancel mistakenly closed panes from hierarchy: \(treeAfterCancel)")
        }

        // Step 8: Trigger Cmd+W again and confirm Close
        d.activate()
        usleep(200_000)
        d.key(Key.w, .maskCommand)

        var closeBtn2: AXUIElement?
        guard d.wait(for: {
            closeBtn2 = d.button(titled: "Close")
            return closeBtn2 != nil
        }, timeout: 5), let closeBtn2 else {
            throw Failure("confirmation dialog did not appear on second Cmd+W")
        }

        d.press(closeBtn2)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("subagent close dialog was not dismissed after Close")
        }

        // Step 9: Verify parent and all recursive descendants are completely removed, and Tab 1 remains
        guard d.wait(for: {
            guard let curTree = try? d.exec("\(ctl) tree --json"),
                  let data = curTree.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = (obj["result"] as? [String: Any]) ?? Optional(obj),
                  let windows = result["windows"] as? [[String: Any]] else {
                return false
            }
            var panes: [String] = []
            for w in windows {
                for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                    for p in (t["panes"] as? [[String: Any]]) ?? [] {
                        if let pid = p["id"] as? String {
                            panes.append(pid)
                        }
                    }
                }
            }
            return !panes.contains(parentId) &&
                   !panes.contains(child1Id) &&
                   !panes.contains(grandChildId) &&
                   panes.contains(tab1PaneId)
        }, timeout: 6) else {
            let remainingTree = (try? d.exec("\(ctl) tree --json")) ?? ""
            throw Failure("parent or child subagent panes were not recursively removed after confirmation: \(remainingTree)")
        }

        // Step 10: Verify unassisted terminal keyboard input recovery in Tab 1 matches original rootTty
        d.activate()
        usleep(400_000)
        try d.run("tty > \(d.path("subagent_recovered_tty")) && echo 'subagent_ok' > \(witness)")
        try d.expect("subagent_witness", "subagent_ok\n", "terminal keyboard input in tab 1 after recursive subagent close")
        let recoveredTty = try d.file("subagent_recovered_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == rootTty else {
            throw Failure("recovered tty does not match root tab 1 tty: expected \(rootTty), got \(recoveredTty)")
        }
        guard let finalFocusedId = try d.focusedPaneId(), finalFocusedId == tab1PaneId else {
            throw Failure("recovered focused pane does not match root tab 1 pane: expected \(tab1PaneId), got \(try d.focusedPaneId() ?? "nil")")
        }
    }),
    ("project-action", "takoctl action discovers repo actions, refuses unapproved execution, approves via trust store, runs action in target split with verified tree geometry, and recovers unassisted original pane/TTY focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let projDir = d.work.appendingPathComponent("project_action_repo")
        let takoDir = projDir.appendingPathComponent(".tako")
        try FileManager.default.createDirectory(at: takoDir, withIntermediateDirectories: true)

        let witnessFile = projDir.appendingPathComponent("action_split_witness.txt")
        let paneWitnessFile = projDir.appendingPathComponent("action_pane_witness.txt")
        let kbWitnessFile = projDir.appendingPathComponent("action_kb_witness.txt")

        let actionsJson = """
        {
          "version": 1,
          "name": "E2EProject",
          "actions": [
            {
              "id": "build-pane",
              "title": "Build Project In Pane",
              "description": "Compiles e2e artifact in current pane",
              "command": ["echo 'action_pane_ok' > '\(paneWitnessFile.path)'"],
              "shell": true,
              "target": "pane"
            },
            {
              "id": "build-split",
              "title": "Build Project Split",
              "description": "Compiles e2e artifact in split",
              "command": ["/bin/sh", "-c", "echo 'action_split_ok' > '\(witnessFile.path)' && sleep 60"],
              "target": "split"
            }
          ]
        }
        """
        try actionsJson.write(to: takoDir.appendingPathComponent("actions.json"), atomically: true, encoding: .utf8)

        // Baseline recording: original TTY and original pane ID
        try d.run("tty > \(d.path("cli_orig_tty"))")
        let originalTty = try d.file("cli_orig_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover root focused pane ID")
        }

        func parseTreePanes() throws -> [String] {
            let tree = try d.exec("\(ctl) tree --json")
            guard let data = tree.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = (root["result"] as? [String: Any]) ?? Optional(root),
                  let windows = result["windows"] as? [[String: Any]] else {
                throw Failure("failed to parse tree JSON: \(tree)")
            }
            var ids: [String] = []
            for w in windows {
                for t in w["tabs"] as? [[String: Any]] ?? [] {
                    for p in t["panes"] as? [[String: Any]] ?? [] {
                        if let id = p["id"] as? String {
                            ids.append(id)
                        }
                    }
                }
            }
            return ids
        }

        let initialPanes = try parseTreePanes()
        guard !initialPanes.isEmpty && initialPanes.contains(originalPaneId) else {
            throw Failure("baseline tree is invalid or missing original pane: \(initialPanes)")
        }
        let initialPaneCount = initialPanes.count

        // Step 1: Discover actions and verify initial untrusted status
        let listOutput = try d.exec("\(ctl) action list --path '\(projDir.path)' --json")
        guard listOutput.contains("\"trusted\":false") || listOutput.contains("\"trusted\": false") else {
            throw Failure("action list did not report untrusted status for new action: \(listOutput)")
        }
        guard listOutput.contains("E2EProject") && listOutput.contains("build-split") && listOutput.contains("build-pane") else {
            throw Failure("action list did not report project name or actions: \(listOutput)")
        }

        // Step 2: Verify unapproved execution refusal via CLI trust barrier
        var runRefused = false
        do {
            _ = try d.exec("\(ctl) action run build-pane --path '\(projDir.path)' --json")
        } catch {
            runRefused = true
        }
        guard runRefused else {
            throw Failure("takoctl action run unapproved action did not fail closed")
        }
        guard !FileManager.default.fileExists(atPath: paneWitnessFile.path) else {
            throw Failure("unapproved project action executed without approval")
        }

        // Step 3: Approve project actions via CLI
        let approveOutput = try d.exec("\(ctl) action approve --path '\(projDir.path)' --json")
        guard approveOutput.contains("\"approved\":true") || approveOutput.contains("\"approved\": true") else {
            throw Failure("action approve did not report approved: true: \(approveOutput)")
        }

        // Step 4: Verify status command reports trusted
        let statusOutput = try d.exec("\(ctl) action status --path '\(projDir.path)' --json")
        guard statusOutput.contains("\"trusted\":true") || statusOutput.contains("\"trusted\": true") else {
            throw Failure("action status did not report trusted status after approval: \(statusOutput)")
        }

        // Step 5: Execute approved action with target .pane
        let runPaneOutput = try d.exec("\(ctl) action run build-pane --path '\(projDir.path)' --json")
        guard runPaneOutput.contains("\"ran\":true") || runPaneOutput.contains("\"ran\": true") else {
            throw Failure("approved action targeting pane did not execute: \(runPaneOutput)")
        }

        guard d.wait(for: {
            guard let content = try? String(contentsOf: paneWitnessFile, encoding: .utf8) else { return false }
            return content == "action_pane_ok\n"
        }, timeout: 6) else {
            throw Failure("witness file was not written with expected content by executed pane action")
        }

        // Step 6: Execute approved action with target .split
        let runSplitOutput = try d.exec("\(ctl) action run build-split --path '\(projDir.path)' --json")
        guard runSplitOutput.contains("\"ran\":true") || runSplitOutput.contains("\"ran\": true") else {
            throw Failure("approved action targeting split did not execute: \(runSplitOutput)")
        }

        // Wait for split witness file written by action
        guard d.wait(for: {
            guard let content = try? String(contentsOf: witnessFile, encoding: .utf8) else { return false }
            return content == "action_split_ok\n"
        }, timeout: 6) else {
            throw Failure("witness file was not written with expected content by executed split action")
        }

        // Assert exact new pane in tree (fail if query fails, and require exactly 1 new pane)
        var splitPaneId: String?
        guard d.wait(for: {
            guard let currentPanes = try? parseTreePanes() else { return false }
            let diff = Set(currentPanes).subtracting(Set(initialPanes))
            if diff.count == 1, let id = diff.first {
                splitPaneId = id
                return true
            }
            return false
        }, timeout: 6), let newPaneId = splitPaneId else {
            throw Failure("project action with target split did not create exactly one new pane in tree")
        }

        // Cleanly close split pane via takoctl close and assert successful cleanup
        let closeOutput = try d.exec("\(ctl) close --target \(newPaneId) --json")
        guard closeOutput.contains("\"state\":\"closed\"") || closeOutput.contains("\"state\": \"closed\"") else {
            throw Failure("takoctl close returned non-closed state: \(closeOutput)")
        }
        guard d.wait(for: {
            guard let currentPanes = try? parseTreePanes() else { return false }
            return currentPanes.count == initialPaneCount &&
                   currentPanes.contains(originalPaneId) &&
                   !currentPanes.contains(newPaneId)
        }, timeout: 6) else {
            let remainingTree = (try? d.exec("\(ctl) tree --json")) ?? ""
            throw Failure("split pane was not cleanly removed from tree: \(remainingTree)")
        }

        // Step 7: Verify unassisted terminal keyboard focus recovery in original pane and matching TTY
        d.activate()
        usleep(500_000)
        try d.run("tty > \(d.path("cli_recovered_tty")) && echo 'keyboard_ok' > '\(kbWitnessFile.path)'")
        guard d.wait(for: {
            (try? String(contentsOf: kbWitnessFile, encoding: .utf8)) == "keyboard_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after project action execution")
        }
        let recoveredTty = try d.file("cli_recovered_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == originalTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match original TTY (\(originalTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane: expected \(originalPaneId), got \(try d.focusedPaneId() ?? "nil")")
        }
    }),
    ("project-action-ui", "shell-reported project cwd populates Command Palette with project actions, cancel refuses execution, Approve & Run executes approved action in UI and recovers unassisted keyboard focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let projDir = d.work.appendingPathComponent("ui_project_repo")
        let takoDir = projDir.appendingPathComponent(".tako")
        try FileManager.default.createDirectory(at: takoDir, withIntermediateDirectories: true)

        let uiPaneWitness = projDir.appendingPathComponent("ui_pane_witness.txt")
        let uiKbWitness = projDir.appendingPathComponent("ui_kb_witness.txt")

        let actionsJson = """
        {
          "version": 1,
          "name": "UIProject",
          "actions": [
            {
              "id": "ui-pane-act",
              "title": "Build UI In Pane",
              "description": "Compiles UI artifact in current pane",
              "command": ["echo 'ui_pane_ok' > '\(uiPaneWitness.path)'"],
              "shell": true,
              "target": "pane"
            }
          ]
        }
        """
        try actionsJson.write(to: takoDir.appendingPathComponent("actions.json"), atomically: true, encoding: .utf8)

        // Step 1: Record original pane ID and TTY
        try d.run("tty > \(d.path("ui_orig_tty"))")
        let origTty = try d.file("ui_orig_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover root focused pane ID in UI journey")
        }

        // Step 2: Change directory in active shell to project fixture and emit OSC 7 cwd report
        try d.run("cd '\(projDir.path)' && printf '\\033]7;file://localhost%s\\007' \"$PWD\"")
        guard d.wait(for: {
            guard let tree = try? d.exec("\(ctl) tree --json"),
                  tree.contains(projDir.path) else { return false }
            return true
        }, timeout: 6) else {
            throw Failure("surface cwd in tree did not update to project dir \(projDir.path)")
        }

        // Step 3: Open Command Palette via menu item
        d.activate()
        usleep(200_000)
        guard d.pressMenuItem(titledPrefix: "Command Palette") else {
            throw Failure("failed to press Command Palette menu item")
        }
        guard d.wait(for: { d.hasText(containing: "Commands") }, timeout: 5) else {
            throw Failure("Command Palette was not presented via menu action")
        }

        // Step 4: Verify project action discovery in Command Palette
        try d.type("Build UI In Pane")
        usleep(400_000)
        guard d.wait(for: {
            d.hasText(containing: "UIProject: Build UI In Pane") || d.hasText(containing: "Project Action") || d.button(titled: "Build UI In Pane") != nil
        }, timeout: 5) else {
            throw Failure("Command Palette did not discover or display project action for current directory")
        }

        // Step 5: Submit action while untrusted -> presents Approve Project Action dialog
        d.key(Key.returnKey)
        var cancelBtn: AXUIElement?
        var approveBtn: AXUIElement?
        guard d.wait(for: {
            cancelBtn = d.button(titled: "Cancel")
            approveBtn = d.button(titled: "Approve & Run")
            return cancelBtn != nil && approveBtn != nil
        }, timeout: 5), let cancelBtn else {
            throw Failure("Approve Project Action confirmation dialog did not appear for untrusted action")
        }
        guard d.hasText(containing: "Approve Project Action?") else {
            throw Failure("dialog does not present expected title text")
        }

        // Step 6: Test Cancel path -> dismisses dialog with NO execution
        d.press(cancelBtn)
        guard d.wait(for: { d.button(titled: "Approve & Run") == nil && d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("Approve Project Action dialog was not dismissed after Cancel")
        }
        guard !FileManager.default.fileExists(atPath: uiPaneWitness.path) else {
            throw Failure("project action executed despite Cancel being pressed")
        }
        let untrustedStatus = try d.exec("\(ctl) action status --path '\(projDir.path)' --json")
        guard untrustedStatus.contains("\"trusted\":false") || untrustedStatus.contains("\"trusted\": false") else {
            throw Failure("action status was marked trusted despite Cancel: \(untrustedStatus)")
        }

        // Step 7: Re-open Command Palette and invoke action to Approve & Run
        d.activate()
        usleep(200_000)
        guard d.pressMenuItem(titledPrefix: "Command Palette") else {
            throw Failure("failed to reopen Command Palette")
        }
        guard d.wait(for: { d.hasText(containing: "Commands") }, timeout: 5) else {
            throw Failure("Command Palette did not reopen")
        }
        try d.type("Build UI In Pane")
        usleep(400_000)
        d.key(Key.returnKey)

        var approveBtn2: AXUIElement?
        guard d.wait(for: {
            approveBtn2 = d.button(titled: "Approve & Run")
            return approveBtn2 != nil
        }, timeout: 5), let approveBtn2 else {
            throw Failure("Approve Project Action dialog did not appear on second invocation")
        }

        // Press Approve & Run
        d.press(approveBtn2)
        guard d.wait(for: { d.button(titled: "Approve & Run") == nil }, timeout: 5) else {
            throw Failure("Approve Project Action dialog was not dismissed after Approve & Run")
        }

        // Verify action executed in pane and wrote expected witness
        guard d.wait(for: {
            (try? String(contentsOf: uiPaneWitness, encoding: .utf8)) == "ui_pane_ok\n"
        }, timeout: 6) else {
            throw Failure("witness file was not written by action executed via Approve & Run")
        }

        // Verify action status is now trusted
        let trustedStatus = try d.exec("\(ctl) action status --path '\(projDir.path)' --json")
        guard trustedStatus.contains("\"trusted\":true") || trustedStatus.contains("\"trusted\": true") else {
            throw Failure("action status was not marked trusted after Approve & Run: \(trustedStatus)")
        }

        // Step 8: Verify unassisted terminal keyboard focus recovery in original pane and matching TTY
        d.activate()
        usleep(500_000)
        try d.run("tty > \(d.path("ui_rec_tty")) && echo 'ui_kb_ok' > '\(uiKbWitness.path)'")
        guard d.wait(for: {
            (try? String(contentsOf: uiKbWitness, encoding: .utf8)) == "ui_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after UI action execution")
        }
        let recoveredTty = try d.file("ui_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == origTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match original TTY (\(origTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane: expected \(originalPaneId), got \(try d.focusedPaneId() ?? "nil")")
        }
    }),
    ("notification-center", "emits base64-encoded structured OSC 99 notification, opens Notification Center, locates row in panel AX subtree, asserts exact title/body with negative control, clears row, dismisses, and recovers unassisted keyboard focus", { d in
        // Step 1: Record initial terminal environment (focused pane ID and TTY)
        try d.run("tty > \(d.path("notif_init_tty"))")
        let initTty = try d.file("notif_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover root focused pane ID for notification center journey")
        }

        // Step 2: First toggle Notification Center on empty state to verify clean initial view
        d.activate()
        usleep(200_000)
        d.key(Key.n, [.maskCommand, .maskAlternate])
        guard d.wait(for: { d.hasText(containing: "Notifications") }, timeout: 5) else {
            throw Failure("notification center 'Notifications' header was not visible after initial Cmd+Opt+N")
        }
        // If there are persisted records from earlier runs, clear them to verify empty state transition
        if let existingClear = d.button(titled: "Clear") ?? d.button(titled: "NotificationCenterClearButton") {
            d.press(existingClear)
            usleep(200_000)
        }
        guard d.wait(for: { d.hasText(containing: "No Notifications") }, timeout: 5) else {
            throw Failure("empty state 'No Notifications' was not visible in initial Notification Center")
        }

        // Dismiss empty panel via Cmd+Option+N toggle
        d.key(Key.n, [.maskCommand, .maskAlternate])
        guard d.wait(for: { !d.hasText(containing: "Notifications") }, timeout: 5) else {
            throw Failure("Notification Center was still visible after Cmd+Opt+N toggle dismissal on empty state")
        }

        // Step 3: Emit structured notification via OSC 99 using base64 payload encoding (:e=1)
        // This guarantees the human-readable title and body NEVER appear in the typed command or terminal screen buffer.
        d.activate()
        usleep(300_000)
        let notifId = "e2e-notif-1"
        let notifTitle = "Automated E2E Notification"
        let notifBody = "Structured notification payload delivered via OSC 99"
        let b64Title = Data(notifTitle.utf8).base64EncodedString()
        let b64Body = Data(notifBody.utf8).base64EncodedString()
        try d.run("printf '\\e]99;i=\(notifId):d=0:e=1;\(b64Title)\\e\\\\'; printf '\\e]99;i=\(notifId):d=1:p=body:e=1;\(b64Body)\\e\\\\';")
        usleep(500_000)

        // Step 4: Open Notification Center via Cmd+Option+N and locate NotificationCenterPanel
        d.activate()
        usleep(200_000)
        d.key(Key.n, [.maskCommand, .maskAlternate])
        guard d.wait(for: { d.element(withIdentifier: "NotificationCenterPanel") != nil }, timeout: 5),
              let panel = d.element(withIdentifier: "NotificationCenterPanel") else {
            throw Failure("Notification Center panel was not found in accessibility hierarchy after Cmd+Opt+N")
        }

        // Locate the uniquely identified emitted record row exclusively within the panel AX subtree
        var rowElement: AXUIElement?
        guard d.wait(for: {
            rowElement = d.element(withIdentifier: "NotificationRow_\(notifId)", root: panel)
            return rowElement != nil
        }, timeout: 5), let row = rowElement else {
            throw Failure("notification row 'NotificationRow_\(notifId)' was not found in Notification Center panel")
        }

        // Assert exact title and body within that specific row's AX subtree
        let rowTexts = d.textValues(under: row)
        guard rowTexts.contains(notifTitle) else {
            throw Failure("expected notification title '\(notifTitle)' was not found in row AX subtree. Row texts: \(rowTexts)")
        }
        guard rowTexts.contains(notifBody) else {
            throw Failure("expected notification body '\(notifBody)' was not found in row AX subtree. Row texts: \(rowTexts)")
        }

        // Negative control: verify that an un-emitted wrong body is absent from the row's AX subtree
        let wrongBody = "Negative Control: Wrong Notification Body"
        guard !rowTexts.contains(wrongBody) else {
            throw Failure("negative control failed: row AX subtree unexpectedly contained wrong body '\(wrongBody)'")
        }

        // Assert unread/caught-up status badge within the notification center panel
        let panelTexts = d.textValues(under: panel)
        guard panelTexts.contains("All caught up") || panelTexts.contains(where: { $0.contains("unread") }) else {
            throw Failure("status badge ('All caught up' or unread count) was not found in Notification Center panel: \(panelTexts)")
        }

        // Step 5: Interact with Clear button in the Notification Center header
        var clearBtn: AXUIElement?
        guard d.wait(for: {
            clearBtn = d.button(titled: "Clear") ?? d.element(withIdentifier: "NotificationCenterClearButton", root: panel)
            return clearBtn != nil
        }, timeout: 5), let btn = clearBtn else {
            throw Failure("Clear button was not found in Notification Center panel")
        }
        d.press(btn)

        // Assert that the uniquely identified row disappears from the AX tree after Clear
        guard d.wait(for: {
            d.element(withIdentifier: "NotificationRow_\(notifId)", root: panel) == nil
        }, timeout: 5) else {
            throw Failure("notification row 'NotificationRow_\(notifId)' was still present in Notification Center after Clear")
        }
        guard d.wait(for: { d.hasText(containing: "No Notifications") }, timeout: 5) else {
            throw Failure("'No Notifications' text did not appear after clicking Clear button")
        }

        // Step 6: Dismiss Notification Center via Cmd+Option+N toggle
        d.key(Key.n, [.maskCommand, .maskAlternate])
        guard d.wait(for: { d.element(withIdentifier: "NotificationCenterPanel") == nil }, timeout: 5) else {
            throw Failure("Notification Center was still visible after Cmd+Opt+N dismissal")
        }

        // Step 7: Verify unassisted terminal keyboard focus recovery in original pane and matching TTY
        d.activate()
        usleep(500_000)
        let witnessFile = d.path("notif_kb_witness.txt")
        try d.run("tty > \(d.path("notif_rec_tty")) && echo 'notif_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "notif_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after notification center dismissal")
        }
        let recoveredTty = try d.file("notif_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match original TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane: expected \(originalPaneId), got \(try d.focusedPaneId() ?? "nil")")
        }
    }),
    ("ctl-status-progress", "exercises takoctl status set/get/clear and progress percentage/pause/error/clear indicators with JSON assertions, negative controls, and unassisted keyboard recovery", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        try d.run("tty > \(d.path("stat_init_tty"))")
        let initTty = try d.file("stat_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused pane ID for status-progress journey")
        }

        // 1. Status set
        let setJson = try d.exec("\(ctl) status set working --text compiling --target \(originalPaneId) --json")
        guard setJson.contains("\"status\":\"working\"") || setJson.contains("\"status\": \"working\"") else {
            throw Failure("status set did not report working status: \(setJson)")
        }
        guard setJson.contains("\"text\":\"compiling\"") || setJson.contains("\"text\": \"compiling\"") else {
            throw Failure("status set did not report status text 'compiling': \(setJson)")
        }

        // 2. Status get
        let getJson = try d.exec("\(ctl) status get --target \(originalPaneId) --json")
        guard getJson.contains("\"status\":\"working\"") || getJson.contains("\"status\": \"working\"") else {
            throw Failure("status get did not report working status: \(getJson)")
        }
        guard getJson.contains("\"text\":\"compiling\"") || getJson.contains("\"text\": \"compiling\"") else {
            throw Failure("status get did not report status text 'compiling': \(getJson)")
        }

        // Negative control: un-set text is absent
        let wrongText = "unexpected_compilation_failure_error"
        guard !getJson.contains(wrongText) else {
            throw Failure("negative control failed: status unexpectedly contained '\(wrongText)': \(getJson)")
        }

        // 3. Progress set, pause, error, clear
        let progSet = try d.exec("\(ctl) progress 45 --target \(originalPaneId) --json")
        guard progSet.contains("\"ok\":true") || progSet.contains("\"ok\": true") else {
            throw Failure("progress set 45 failed: \(progSet)")
        }

        let progPause = try d.exec("\(ctl) progress pause 60 --target \(originalPaneId) --json")
        guard progPause.contains("\"ok\":true") || progPause.contains("\"ok\": true") else {
            throw Failure("progress pause 60 failed: \(progPause)")
        }

        let progError = try d.exec("\(ctl) progress error --target \(originalPaneId) --json")
        guard progError.contains("\"ok\":true") || progError.contains("\"ok\": true") else {
            throw Failure("progress error failed: \(progError)")
        }

        let progClear = try d.exec("\(ctl) progress clear --target \(originalPaneId) --json")
        guard progClear.contains("\"ok\":true") || progClear.contains("\"ok\": true") else {
            throw Failure("progress clear failed: \(progClear)")
        }

        // 4. Status clear
        let clearJson = try d.exec("\(ctl) status clear --target \(originalPaneId) --json")
        guard clearJson.contains("\"ok\":true") || clearJson.contains("\"ok\": true") else {
            throw Failure("status clear failed: \(clearJson)")
        }

        let getAfterClear = try d.exec("\(ctl) status get --target \(originalPaneId) --json")
        guard !getAfterClear.contains("\"status\":\"working\"") && !getAfterClear.contains("\"text\":\"compiling\"") else {
            throw Failure("status get still contained cleared status or text: \(getAfterClear)")
        }

        // 5. Unassisted keyboard recovery
        d.activate()
        usleep(300_000)
        let witnessFile = d.path("status_kb_witness.txt")
        try d.run("tty > \(d.path("stat_rec_tty")) && echo 'status_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "status_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after status-progress commands")
        }
        let recoveredTty = try d.file("stat_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match initial TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane")
        }
    }),
    ("ctl-activity", "records automated input activity attribution, verifies activity entries via JSON, exports log to file, clears log, and recovers unassisted keyboard focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        try d.run("tty > \(d.path("act_init_tty"))")
        let initTty = try d.file("act_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused pane ID for activity journey")
        }

        // 1. Clear any prior activity and permit external automation on this pane
        _ = try? d.exec("\(ctl) activity clear \(originalPaneId) --json")
        _ = try d.exec("\(ctl) input allow-automation --target \(originalPaneId)")

        // 2. Perform automated input with client attribution
        let agentClient = "e2e-test-agent"
        try d.exec("\(ctl) type 'echo act_witness_ok' --target \(originalPaneId) --client \(agentClient)")
        _ = try? d.exec("\(ctl) key Return --target \(originalPaneId)")
        usleep(400_000)

        // 3. Inspect activity log
        var activityJson = ""
        guard d.wait(for: {
            guard let out = try? d.exec("\(ctl) activity \(originalPaneId) --json"),
                  out.contains(agentClient),
                  out.contains("\"action\":\"type\"") || out.contains("\"action\": \"type\"") else {
                return false
            }
            activityJson = out
            return true
        }, timeout: 5) else {
            throw Failure("activity log did not record attributed client '\(agentClient)': \(activityJson)")
        }

        // 4. Export activity log to file
        let exportPath = d.path("activity_export.json")
        let expResult = try d.exec("\(ctl) activity --export '\(exportPath)' \(originalPaneId) --json")
        guard expResult.contains("\"exported\"") || expResult.contains("exported") else {
            throw Failure("exporting activity log failed: \(expResult)")
        }
        let exportedContent = try d.file("activity_export.json")
        guard exportedContent.contains(agentClient), exportedContent.contains("type") else {
            throw Failure("exported activity log file missing expected entries: \(exportedContent)")
        }

        // 5. Clear activity log
        let clearResult = try d.exec("\(ctl) activity clear \(originalPaneId) --json")
        guard clearResult.contains("\"cleared\":true") || clearResult.contains("\"cleared\": true") else {
            throw Failure("activity clear failed: \(clearResult)")
        }

        // 6. Negative control: verify entries are cleared
        let afterClear = try d.exec("\(ctl) activity \(originalPaneId) --json")
        guard !afterClear.contains(agentClient) else {
            throw Failure("negative control failed: activity log still contained '\(agentClient)' after clear: \(afterClear)")
        }

        // 7. Unassisted keyboard recovery
        d.activate()
        usleep(300_000)
        let witnessFile = d.path("act_kb_witness.txt")
        try d.run("tty > \(d.path("act_rec_tty")) && echo 'activity_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "activity_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after activity commands")
        }
        let recoveredTty = try d.file("act_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match initial TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane")
        }
    }),
    ("ctl-triggers", "registers passive regex triggers via takoctl, verifies active triggers in JSON list, removes specific trigger, clears all dynamic triggers, and recovers unassisted keyboard focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        try d.run("tty > \(d.path("trig_init_tty"))")
        let initTty = try d.file("trig_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused pane ID for triggers journey")
        }

        // 1. Clear any prior dynamic triggers
        _ = try? d.exec("\(ctl) triggers clear --json")

        // 2. Add dynamic passive regex trigger
        let triggerPattern = "FATAL_ERROR_[0-9]+"
        let addJson = try d.exec("\(ctl) triggers add '\(triggerPattern)' --action highlight --color red --style box --all-focus --json")
        guard addJson.contains("FATAL_ERROR_"),
              addJson.contains("\"action\":\"highlight\"") || addJson.contains("\"action\": \"highlight\"") else {
            throw Failure("triggers add did not return expected trigger definition: \(addJson)")
        }

        // Extract trigger id
        guard let idMatch = addJson.range(of: "\"id\"\\s*:\\s*\"([a-f0-9\\-]+)\"", options: .regularExpression) else {
            throw Failure("failed to extract trigger ID from add response: \(addJson)")
        }
        let idSubstr = String(addJson[idMatch])
        let triggerId = idSubstr.components(separatedBy: "\"")[3]

        // 3. List triggers and verify
        let listJson = try d.exec("\(ctl) triggers list --json")
        guard listJson.contains(triggerId), listJson.contains("FATAL_ERROR_") else {
            throw Failure("triggers list missing newly added trigger: \(listJson)")
        }

        // 4. Negative control: adding invalid regex pattern fails
        let invalidRes = try? d.exec("\(ctl) triggers add '[unclosed-regex' --json")
        guard invalidRes == nil || invalidRes?.contains("\"ok\":false") == true || invalidRes?.contains("\"ok\": false") == true else {
            throw Failure("negative control failed: invalid regex pattern was accepted")
        }

        // 5. Remove the specific trigger by ID
        let rmJson = try d.exec("\(ctl) triggers remove \(triggerId) --json")
        guard rmJson.contains("\"removed\"") else {
            throw Failure("triggers remove failed: \(rmJson)")
        }
        let listAfterRm = try d.exec("\(ctl) triggers list --json")
        guard !listAfterRm.contains(triggerId) else {
            throw Failure("triggers list still contained removed trigger ID \(triggerId): \(listAfterRm)")
        }

        // 6. Add another temporary trigger, then clear all
        _ = try d.exec("\(ctl) triggers add 'TEMP_TRIG' --action notify --title 'Temp Notice' --json")
        let clearJson = try d.exec("\(ctl) triggers clear --json")
        guard clearJson.contains("\"cleared\":true") || clearJson.contains("\"cleared\": true") else {
            throw Failure("triggers clear failed: \(clearJson)")
        }
        let listAfterClear = try d.exec("\(ctl) triggers list --json")
        guard !listAfterClear.contains("TEMP_TRIG") else {
            throw Failure("triggers list still contained dynamic trigger after clear: \(listAfterClear)")
        }

        // 7. Unassisted keyboard recovery
        d.activate()
        usleep(300_000)
        let witnessFile = d.path("trig_kb_witness.txt")
        try d.run("tty > \(d.path("trig_rec_tty")) && echo 'triggers_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "triggers_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after triggers commands")
        }
        let recoveredTty = try d.file("trig_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match initial TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane")
        }
    }),
    ("ctl-resume", "binds session resume command and directory to pane, inspects state, verifies approval flag, clears resume binding, and recovers unassisted keyboard focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        try d.run("tty > \(d.path("res_init_tty"))")
        let initTty = try d.file("res_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused pane ID for resume journey")
        }

        let resumeProj = d.work.appendingPathComponent("resume_target_repo")
        try FileManager.default.createDirectory(at: resumeProj, withIntermediateDirectories: true)

        // 1. Set resume binding on current pane
        let setRes = try d.exec("\(ctl) resume set --cwd '\(resumeProj.path)' --target \(originalPaneId) -- e2e-worker --session s-42")
        guard setRes.contains("\"ok\":true") || setRes.contains("\"ok\": true") || setRes.contains("e2e-worker") else {
            throw Failure("resume set command failed: \(setRes)")
        }

        // 2. Show resume state via JSON
        let showJson = try d.exec("\(ctl) resume show \(originalPaneId) --json")
        guard showJson.contains("\"has_resume\":true") || showJson.contains("\"has_resume\": true") else {
            throw Failure("resume show did not indicate has_resume: true: \(showJson)")
        }
        guard showJson.contains("e2e-worker"), showJson.contains("s-42"), showJson.contains(resumeProj.path) else {
            throw Failure("resume show missing expected command vector or cwd: \(showJson)")
        }

        // 3. Approve resume
        let approveRes = try d.exec("\(ctl) resume approve --prefix e2e-worker \(originalPaneId) --json")
        guard approveRes.contains("\"ok\":true") || approveRes.contains("\"ok\": true") || approveRes.contains("approved") else {
            throw Failure("resume approve failed: \(approveRes)")
        }
        let showApproved = try d.exec("\(ctl) resume show \(originalPaneId) --json")
        guard showApproved.contains("\"approved\":true") || showApproved.contains("\"approved\": true") else {
            throw Failure("resume show did not reflect approved state: \(showApproved)")
        }

        // 4. Clear resume binding
        let clearRes = try d.exec("\(ctl) resume clear \(originalPaneId) --json")
        guard clearRes.contains("\"cleared\":true") || clearRes.contains("\"cleared\": true") || clearRes.contains("Resume session cleared") else {
            throw Failure("resume clear failed: \(clearRes)")
        }

        // 5. Negative control: resume show after clear reflects has_resume: false
        let showCleared = try d.exec("\(ctl) resume show \(originalPaneId) --json")
        guard showCleared.contains("\"has_resume\":false") || showCleared.contains("\"has_resume\": false") else {
            throw Failure("negative control failed: resume show still reported has_resume: true after clear: \(showCleared)")
        }

        // 6. Unassisted keyboard recovery
        d.activate()
        usleep(300_000)
        let witnessFile = d.path("res_kb_witness.txt")
        try d.run("tty > \(d.path("res_rec_tty")) && echo 'resume_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "resume_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after resume commands")
        }
        let recoveredTty = try d.file("res_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match initial TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane")
        }
    }),
    ("ctl-tasks", "creates git worktree task on repo, queries task list and status via takoctl, finishes task, and recovers unassisted keyboard focus", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        try d.run("tty > \(d.path("task_init_tty"))")
        let initTty = try d.file("task_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originalPaneId = try d.focusedPaneId() else {
            throw Failure("failed to discover focused pane ID for tasks journey")
        }

        // 1. Set up an isolated git repository fixture
        let taskRepo = d.work.appendingPathComponent("task_fixture_repo")
        try FileManager.default.createDirectory(at: taskRepo, withIntermediateDirectories: true)
        _ = try d.exec("git init -b main '\(taskRepo.path)' && cd '\(taskRepo.path)' && git config user.email 'alex@prod.codes' && git config user.name 'Alex' && echo 'base repo' > README.md && git add README.md && git commit -m 'Initial base commit'")

        // 2. Create git worktree task
        let taskName = "e2e-task-branch"
        let createRes = try d.exec("\(ctl) task create \(taskName) --branch feat/e2e-task --base main --path '\(taskRepo.path)' --json")
        guard createRes.contains("\"created\":true") || createRes.contains("\"created\": true"),
              createRes.contains(taskName) else {
            throw Failure("task create failed or did not report creation: \(createRes)")
        }
        let taskPaneId = try d.focusedPaneId()

        // 3. List tasks and verify
        let listRes = try d.exec("\(ctl) task list '\(taskRepo.path)' --json")
        guard listRes.contains(taskName), listRes.contains("feat/e2e-task") else {
            throw Failure("task list does not contain newly created task: \(listRes)")
        }

        // 4. Query task status
        let statusRes = try d.exec("\(ctl) task status \(taskName) --path '\(taskRepo.path)' --json")
        guard statusRes.contains(taskName), statusRes.contains("feat/e2e-task") else {
            throw Failure("task status query failed: \(statusRes)")
        }

        // 5. Negative control: status on non-existent task fails
        let nonExistentRes = try? d.exec("\(ctl) task status non_existent_task_xyz --path '\(taskRepo.path)' --json")
        guard nonExistentRes == nil || nonExistentRes?.contains("\"ok\":false") == true || nonExistentRes?.contains("\"ok\": false") == true else {
            throw Failure("negative control failed: non-existent task status succeeded unexpectedly")
        }

        // 6. Finish task and cleanly close task tab
        _ = try? d.exec("\(ctl) task finish \(taskName) --path '\(taskRepo.path)' --json")
        if let tid = taskPaneId, tid != originalPaneId {
            _ = try? d.exec("\(ctl) close --target \(tid) --json")
        }
        _ = try? d.exec("\(ctl) focus \(originalPaneId)")

        // 7. Unassisted keyboard recovery
        d.activate()
        _ = try? d.exec("\(ctl) focus \(originalPaneId)")
        usleep(400_000)
        let witnessFile = d.path("task_kb_witness.txt")
        try d.run("tty > \(d.path("task_rec_tty")) && echo 'task_kb_ok' > '\(witnessFile)'")
        guard d.wait(for: {
            (try? String(contentsOf: URL(fileURLWithPath: witnessFile), encoding: .utf8)) == "task_kb_ok\n"
        }, timeout: 6) else {
            throw Failure("terminal keyboard input was not functional after task commands")
        }
        let recoveredTty = try d.file("task_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveredTty == initTty else {
            throw Failure("recovered TTY (\(recoveredTty)) does not match initial TTY (\(initTty))")
        }
        guard let finalFocused = try d.focusedPaneId(), finalFocused == originalPaneId else {
            throw Failure("recovered focused pane does not match original pane")
        }
    }),
    ("workspace-journey", "dragging window, creating tabs, mouse-switching tabs, and switching workspaces work end-to-end", { d in
        func clickWorkspaceItem(_ title: String) throws {
            guard d.wait(for: { d.openMenuItem(titled: title) != nil }, timeout: 5),
                  let item = d.openMenuItem(titled: title),
                  let position: AXValue = d.attribute(item, kAXPositionAttribute),
                  let size: AXValue = d.attribute(item, kAXSizeAttribute) else {
                throw Failure("workspace item '\(title)' has no visible frame")
            }
            var origin = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position, .cgPoint, &origin)
            AXValueGetValue(size, .cgSize, &extent)
            try d.click(at: CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2))
        }
        // Clean start with pill style config
        d.quit()
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let wsDir = appSupport.appendingPathComponent(d.bundleID).appendingPathComponent("Workspaces")
            try? FileManager.default.removeItem(at: wsDir)
        }
        try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\ntab-style = pill\n")
        d.setPosition(CGPoint(x: 100, y: 100))
        d.setSize(CGSize(width: 800, height: 500))
        d.focus()
        usleep(1_000_000)

        let initialWorkspaces = (try? d.workspaceList()) ?? []
        let defaultWsIdStr = initialWorkspaces.first(where: { ($0["name"] as? String) == "Default" })?["id"] as? String
            ?? "00000000-0000-0000-0000-000000000001"

        // --- PHASE 1: Default Workspace ---
        // 1. Initial window dragging verification with real CGEvent drag
        guard let f1 = d.windowFrame() else {
            throw Failure("no window frame discovered for initial window in Default workspace")
        }
        // The first tab occupies x=250 in pill style. Drag the empty space
        // between the tabs and the controls at the right edge instead.
        let dragStart1 = CGPoint(x: f1.maxX - 150, y: f1.origin.y + 18)
        let dragEnd1 = CGPoint(x: dragStart1.x + 80, y: dragStart1.y + 40)
        try d.drag(from: dragStart1, to: dragEnd1, steps: 12)
        usleep(500_000)
        guard let draggedF1 = d.windowFrame() else {
            throw Failure("no window frame after dragging initial window")
        }
        guard draggedF1.origin != f1.origin,
              draggedF1.origin.x >= f1.origin.x + 15 else {
            throw Failure("initial window dragging failed (initial: \(f1.origin), dragged: \(draggedF1.origin))")
        }

        // Record on-screen window numbers belonging to Workspace A
        let wsA_windows = d.onScreenWindowNumbers()
        guard !wsA_windows.isEmpty else {
            throw Failure("no on-screen window numbers detected for Workspace A")
        }
        var allWsA_windows = wsA_windows

        // 2. Read initial Tab 0 TTY
        try d.run("tty > \(d.path("ws1_tab0_init.txt"))")
        let ws1_tab0 = try d.file("ws1_tab0_init.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws1_tab0.isEmpty else { throw Failure("could not read initial tab TTY") }

        // 3. Create second tab in Default workspace via Cmd+T
        d.key(Key.t, .maskCommand)
        guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else {
            throw Failure("second tab element tab-1 did not appear in Default workspace")
        }
        usleep(1_000_000)
        allWsA_windows.formUnion(d.onScreenWindowNumbers())

        // Type unassisted into newly created tab
        try d.run("tty > \(d.path("ws1_tab1_created.txt"))")
        let ws1_tab1 = try d.file("ws1_tab1_created.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws1_tab1.isEmpty, ws1_tab1 != ws1_tab0 else {
            throw Failure("second tab in Default workspace did not spawn a distinct TTY (tab0: \(ws1_tab0), tab1: \(ws1_tab1))")
        }

        // 4. Real mouse click switching back to Tab 0 (located via accessibility)
        try d.clickTab(index: 0)
        // Type unassisted without any focus repair
        try d.run("tty > \(d.path("ws1_tab0_switched.txt"))")
        let ws1_tab0_switched = try d.file("ws1_tab0_switched.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ws1_tab0_switched == ws1_tab0 else {
            throw Failure("mouse click on Tab 0 did not route unassisted input to Tab 0 (got: \(ws1_tab0_switched), expected: \(ws1_tab0))")
        }

        // 5. Real mouse click switching back to Tab 1 (located via accessibility)
        try d.clickTab(index: 1)
        // Type unassisted without any focus repair
        try d.run("tty > \(d.path("ws1_tab1_switched.txt"))")
        let ws1_tab1_switched = try d.file("ws1_tab1_switched.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ws1_tab1_switched == ws1_tab1 else {
            throw Failure("mouse click on Tab 1 did not route unassisted input to Tab 1 (got: \(ws1_tab1_switched), expected: \(ws1_tab1))")
        }
        // Tab 1 remains the selected tab in Window 1!
        // 5b. Create second independent window in Workspace A via Cmd+N
        let winCountBefore = d.windows().count
        d.key(Key.n, .maskCommand)
        guard d.wait(for: { d.windows().count == winCountBefore + 1 }, timeout: 5) else {
            throw Failure("Cmd+N did not open second window in Workspace A")
        }
        usleep(1_000_000)
        let wsA_allWindows = d.onScreenWindowNumbers()
        guard wsA_allWindows.count >= 2 else {
            throw Failure("Workspace A does not have 2 on-screen windows (found: \(wsA_allWindows))")
        }
        allWsA_windows.formUnion(wsA_allWindows)

        // Record the second window's active ID and unassisted TTY witness
        guard let win2Element = d.activeOnScreenWindow(),
              let win2Id = d.windowID(for: win2Element) else {
            throw Failure("could not identify active on-screen window after Cmd+N in Workspace A")
        }
        try d.run("tty > \(d.path("ws1_win2_created.txt"))")
        let ws1_win2 = try d.file("ws1_win2_created.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws1_win2.isEmpty, ws1_win2 != ws1_tab0, ws1_win2 != ws1_tab1 else {
            throw Failure("second window in Workspace A did not spawn a distinct TTY (got: \(ws1_win2))")
        }
        let wsABeforeLeaving = try d.workspaceList()

        // --- PHASE 2: Create and Exercise New Workspace (B) ---
        // 6. Create Workspace 2 via real mouse click on the Workspace Pill and popup menu
        try d.clickWorkspacePill()
        try clickWorkspaceItem("New Workspace...")

        // Wait for modal alert and click "Create" button with real mouse click alone (NO fallbacks)
        guard d.wait(for: { d.button(titled: "Create") != nil }, timeout: 5) else {
            throw Failure("New Project Workspace alert dialog did not appear")
        }
        usleep(300_000)
        try d.clickButton(titled: "Create")
        guard d.wait(for: { d.button(titled: "Create") == nil }, timeout: 5) else {
            let wsCount = (try? d.workspaceList().count) ?? -1
            let wsList = (try? d.workspaceList()) ?? []
            let onScreen = d.onScreenWindowNumbers()
            let wins = d.windows().map { win -> String in
                let title: String = d.attribute(win, kAXTitleAttribute) ?? "none"
                let role: String = d.attribute(win, kAXRoleAttribute) ?? "none"
                let subrole: String = d.attribute(win, kAXSubroleAttribute) ?? "none"
                return "\(role)/\(subrole): \(title)"
            }
            throw Failure("New Project Workspace alert dialog was not dismissed after clicking Create (wsCount: \(wsCount), wsList: \(wsList), onScreen: \(onScreen), windows: \(wins))")
        }
        usleep(1_500_000)

        // Verify exactly one new workspace was created in the model
        guard d.wait(for: { (try? d.workspaceList().count) == initialWorkspaces.count + 1 }, timeout: 5) else {
            throw Failure("expected exactly \(initialWorkspaces.count + 1) workspaces after creating new workspace")
        }
        let workspacesAfterCreate = try d.workspaceList()
        let ws2Info = workspacesAfterCreate.first(where: { ws in
            let id = ws["id"] as? String
            return !initialWorkspaces.contains(where: { ($0["id"] as? String) == id }) &&
                   (ws["name"] as? String) != "Default"
        }) ?? workspacesAfterCreate.first(where: { ($0["name"] as? String) != "Default" })
        let ws2IdStr = (ws2Info?["id"] as? String) ?? ""
        guard let ws2Name = ws2Info?["name"] as? String else {
            throw Failure("new workspace record not found in workspace list")
        }

        // 7. Verify new workspace spawned a separate on-screen window and terminal
        guard d.windowFrame() != nil else {
            throw Failure("no window frame discovered for Workspace 2 window")
        }
        let wsB_windows = d.onScreenWindowNumbers()
        guard !wsB_windows.isEmpty else {
            throw Failure("no on-screen windows found for Workspace 2")
        }
        // Verify inactive Workspace A windows are hidden from the on-screen set
        guard wsB_windows.isDisjoint(with: allWsA_windows) else {
            throw Failure("Workspace A windows (\(allWsA_windows)) remained visible after switching to Workspace 2 (\(wsB_windows))")
        }
        var allWsB_windows = wsB_windows

        try d.run("tty > \(d.path("ws2_tab0_init.txt"))")
        let ws2_tab0 = try d.file("ws2_tab0_init.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws2_tab0.isEmpty, ws2_tab0 != ws1_tab0, ws2_tab0 != ws1_tab1 else {
            throw Failure("new Workspace 2 did not activate a separate terminal (got: \(ws2_tab0), ws1_tab0: \(ws1_tab0), ws1_tab1: \(ws1_tab1))")
        }

        // 8. Test window dragging on Workspace 2 window by its titlebar
        // Reserve an empty part of the strip regardless of saved window size.
        d.setSize(CGSize(width: 800, height: 500))
        guard let preDragF2 = d.windowFrame() else {
            throw Failure("no window frame before dragging Workspace 2 window")
        }
        let dragStart2 = CGPoint(x: preDragF2.maxX - 150, y: preDragF2.origin.y + 18)
        let dragEnd2 = CGPoint(x: dragStart2.x + 100, y: dragStart2.y + 52)
        try d.drag(from: dragStart2, to: dragEnd2, steps: 16)
        usleep(500_000)
        guard let draggedF2 = d.windowFrame() else {
            throw Failure("no window frame after dragging Workspace 2 window")
        }
        guard draggedF2.origin != preDragF2.origin,
              (draggedF2.origin.x >= preDragF2.origin.x + 10 || draggedF2.origin.y >= preDragF2.origin.y + 10) else {
            throw Failure("Workspace 2 window dragging failed (initial: \(preDragF2.origin), dragged: \(draggedF2.origin))")
        }

        // 9. Create second tab in Workspace 2 using REAL MOUSE CLICK on the plus button (+)
        try d.clickPlusButton()
        guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else {
            throw Failure("second tab element tab-1 did not appear in Workspace 2 after clicking plus button")
        }
        usleep(1_000_000)
        allWsB_windows.formUnion(d.onScreenWindowNumbers())

        // Type unassisted into newly created tab in Workspace 2
        try d.run("tty > \(d.path("ws2_tab1_created.txt"))")
        let ws2_tab1 = try d.file("ws2_tab1_created.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws2_tab1.isEmpty, ws2_tab1 != ws2_tab0, ws2_tab1 != ws1_tab0, ws2_tab1 != ws1_tab1 else {
            throw Failure("second tab in Workspace 2 did not spawn a distinct TTY (tab0: \(ws2_tab0), tab1: \(ws2_tab1))")
        }

        // 10. Switch between tabs in Workspace 2 via real mouse clicks
        try d.clickTab(index: 0)
        try d.run("tty > \(d.path("ws2_tab0_switched.txt"))")
        let ws2_tab0_switched = try d.file("ws2_tab0_switched.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ws2_tab0_switched == ws2_tab0 else {
            throw Failure("mouse click on Workspace 2 Tab 0 failed to route input (got: \(ws2_tab0_switched), expected: \(ws2_tab0))")
        }

        try d.clickTab(index: 1)
        try d.run("tty > \(d.path("ws2_tab1_switched.txt"))")
        let ws2_tab1_switched = try d.file("ws2_tab1_switched.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ws2_tab1_switched == ws2_tab1 else {
            throw Failure("mouse click on Workspace 2 Tab 1 failed to route input (got: \(ws2_tab1_switched), expected: \(ws2_tab1))")
        }
        // Tab 1 remains active in Workspace 2!
        let wsB_activeWindows = d.onScreenWindowNumbers()
        guard !wsB_activeWindows.isEmpty else {
            throw Failure("no on-screen window numbers detected for Workspace B after selecting Tab 1")
        }

        // --- PHASE 3: Complete Roundtrip Switching & State Retention (A -> B -> A -> B) ---
        // 11. Switch back to Default workspace (A) via real mouse click on the Workspace Pill menu
        try d.clickWorkspacePill()
        try clickWorkspaceItem("Default")
        usleep(1_500_000)

        // Verify inactive Workspace B windows are hidden and all Workspace A windows are restored visible
        let onScreenA = d.onScreenWindowNumbers()
        guard onScreenA.intersection(allWsB_windows).isEmpty else {
            throw Failure("Workspace B windows (\(allWsB_windows)) were not hidden after switching back to Default workspace (on-screen: \(onScreenA))")
        }
        guard onScreenA == wsA_allWindows else {
            throw Failure("Workspace A windows were not restored to on-screen set (on-screen: \(onScreenA), expected: \(wsA_allWindows))")
        }

        // 12. Verify Default workspace unassisted keyboard routing and remembered active Window 2
        guard let restoredActiveWin = d.activeOnScreenWindow(),
              let restoredActiveWid = d.windowID(for: restoredActiveWin) else {
            throw Failure("could not identify active on-screen window after returning to Workspace A")
        }
        guard restoredActiveWid == win2Id else {
            let workspaces = (try? d.workspaceList()) ?? []
            let transitions = (try? d.tabTransitions()) ?? []
            throw Failure("switching back to Workspace A did not restore remembered active window (got wid: \(restoredActiveWid), expected wid: \(win2Id); before: \(wsABeforeLeaving); after: \(workspaces); tab transitions: \(transitions))")
        }
        try d.run("tty > \(d.path("ws1_roundtrip_a.txt"))")
        let restoredTTY_A = try d.file("ws1_roundtrip_a.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard restoredTTY_A == ws1_win2 else {
            throw Failure("switching back to Default workspace did not restore active Window 2! (got: \(restoredTTY_A), expected: \(ws1_win2), tab1 was: \(ws1_tab1), tab0 was: \(ws1_tab0))")
        }

        // 13. Switch back to Workspace 2 (B) via real mouse click on the Workspace Pill menu
        usleep(500_000)
        try d.clickWorkspacePill()
        try clickWorkspaceItem(ws2Name)
        usleep(1_500_000)

        // Verify inactive Workspace A windows are hidden and Workspace B window is visible
        let onScreenB = d.onScreenWindowNumbers()
        guard onScreenB.intersection(allWsA_windows).isEmpty else {
            throw Failure("Workspace A windows (\(allWsA_windows)) were not hidden after switching back to Workspace 2 (on-screen: \(onScreenB))")
        }
        guard onScreenB == wsB_activeWindows else {
            throw Failure("Workspace B window was not restored to on-screen set (on-screen: \(onScreenB), expected: \(wsB_activeWindows))")
        }

        // 14. Verify Workspace 2 unassisted keyboard routing and remembered Tab 1
        try d.run("tty > \(d.path("ws2_roundtrip_b.txt"))")
        let restoredTTY_B = try d.file("ws2_roundtrip_b.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard restoredTTY_B == ws2_tab1 else {
            throw Failure("switching back to Workspace 2 did not restore its active Tab 1! (got: \(restoredTTY_B), expected: \(ws2_tab1), tab0 was: \(ws2_tab0))")
        }

        // --- PHASE 4: Rapid Transitions Within Delay Window (<150ms) ---
        // 15. Rapidly switch workspaces B -> Default (A) -> B within bounded race window (<140ms dispatch)
        // Record baseline sequence so we can verify exact intermediate and final transitions
        let transitionsBefore = (try? d.workspaceTransitions()) ?? []
        let baselineWsSeq = transitionsBefore.compactMap { ($0["sequence"] as? NSNumber)?.int64Value }.max() ?? 0

        let tWs0 = d.postKey(Key.leftBracket, [.maskControl, .maskAlternate])
        usleep(25_000) // 25ms: within the callback window
        let tWs1 = d.postKey(Key.rightBracket, [.maskControl, .maskAlternate])
        let wsDispatchIntervalMs = (tWs1 - tWs0) * 1000.0
        guard wsDispatchIntervalMs < 140.0 else {
            throw Failure("rapid workspace switch dispatch interval exceeded race window: \(wsDispatchIntervalMs)ms (expected < 140ms)")
        }

        // Allow delayed callbacks (50ms and 150ms) to run and settle
        usleep(500_000)

        // Confirm both intermediate and final transitions via app-side transition history
        let transitionsAfter = (try? d.workspaceTransitions()) ?? []
        let newWsTransitions = transitionsAfter.filter { (($0["sequence"] as? NSNumber)?.int64Value ?? 0) > baselineWsSeq }
        guard newWsTransitions.count >= 2 else {
            throw Failure("expected at least 2 transitions recorded during rapid switch, found \(newWsTransitions.count) (total: \(transitionsAfter.count), baselineSeq: \(baselineWsSeq))")
        }
        let intermediateTransition = newWsTransitions[0]
        let finalTransition = newWsTransitions[1]

        let intermediateTo = intermediateTransition["to_id"] as? String ?? ""
        guard intermediateTo == defaultWsIdStr.lowercased() else {
            throw Failure("intermediate rapid transition went to \(intermediateTo), expected Default (\(defaultWsIdStr))")
        }
        let finalTo = finalTransition["to_id"] as? String ?? ""
        guard finalTo == ws2IdStr.lowercased() else {
            throw Failure("final rapid transition went to \(finalTo), expected Workspace 2 (\(ws2IdStr))")
        }

        guard let ts0 = intermediateTransition["timestamp"] as? Double,
              let ts1 = finalTransition["timestamp"] as? Double else {
            throw Failure("missing timestamps on recorded workspace transitions")
        }
        guard ts1 >= ts0 else {
            throw Failure("app-side transition timestamp order invalid (ts0=\(ts0), ts1=\(ts1))")
        }
        let wsTransitionIntervalMs = (ts1 - ts0) * 1000.0
        guard wsTransitionIntervalMs < 140.0 else {
            throw Failure("app-side workspace transition interval exceeded race window: \(wsTransitionIntervalMs)ms (expected < 140ms)")
        }

        // Verify inactive Workspace A windows were not re-shown by any stale delayed callbacks
        let rapidOnScreenB = d.onScreenWindowNumbers()
        guard rapidOnScreenB.intersection(allWsA_windows).isEmpty else {
            throw Failure("rapid workspace transition leaked inactive Workspace A windows into on-screen set: \(rapidOnScreenB.intersection(allWsA_windows)), onScreen: \(rapidOnScreenB), expected B: \(wsB_activeWindows)")
        }
        guard rapidOnScreenB == wsB_activeWindows else {
            throw Failure("rapid workspace transition failed to keep Workspace B window visible (got: \(rapidOnScreenB), expected: \(wsB_activeWindows))")
        }

        // Verify unassisted keyboard typing in Workspace B after rapid transition
        try d.run("tty > \(d.path("ws2_rapid_ws.txt"))")
        let rapidWsTTY = try d.file("ws2_rapid_ws.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard rapidWsTTY == ws2_tab1 else {
            throw Failure("rapid workspace transition failed to route unassisted input to Workspace B Tab 1 (got: \(rapidWsTTY), expected: \(ws2_tab1))")
        }

        // 16. Rapid tab switching within Workspace B (click Tab 0 then Tab 1 within bounded race window)
        // Pre-resolve safe target geometry to avoid helper settling delays
        let tab0Point = try d.tabClickPoint(index: 0)
        let tab1Point = try d.tabClickPoint(index: 1)

        // Query tabs for Workspace 2 to determine expected stable tab IDs
        let wsList = try d.workspaceList()
        guard let ws2Info = wsList.first(where: { ($0["id"] as? String)?.lowercased() == ws2IdStr.lowercased() }),
              let ws2Tabs = ws2Info["tabs"] as? [String], ws2Tabs.count >= 2 else {
            throw Failure("cannot resolve tabs for Workspace 2 before rapid tab switch")
        }
        let expectedTab0Id = ws2Tabs[0]
        let expectedTab1Id = ws2Tabs[1]

        let tabTransitionsBefore = (try? d.tabTransitions()) ?? []
        let baselineTabSeq = tabTransitionsBefore.compactMap { ($0["sequence"] as? NSNumber)?.int64Value }.max() ?? 0

        let tTab0 = try d.postClick(at: tab0Point)
        usleep(40_000) // 40ms: within the callback window (<150ms)
        let tTab1 = try d.postClick(at: tab1Point)
        let tabDispatchIntervalMs = (tTab1 - tTab0) * 1000.0
        guard tabDispatchIntervalMs < 140.0 else {
            throw Failure("rapid tab switch dispatch interval exceeded race window: \(tabDispatchIntervalMs)ms (expected < 140ms)")
        }

        // Allow delayed callbacks (50ms and 150ms) to run and settle
        usleep(500_000)

        // Confirm both intermediate and final transitions via app-side tab transition history
        let tabTransitionsAfter = (try? d.tabTransitions()) ?? []
        let newTabTransitions = tabTransitionsAfter.filter { (($0["sequence"] as? NSNumber)?.int64Value ?? 0) > baselineTabSeq }
        guard newTabTransitions.count >= 2 else {
            throw Failure("expected at least 2 tab transitions recorded during rapid switch, found \(newTabTransitions.count) (total: \(tabTransitionsAfter.count), baselineSeq: \(baselineTabSeq))")
        }
        let intermediateTab = newTabTransitions[0]
        let finalTab = newTabTransitions[1]

        let intermediateWs = (intermediateTab["workspace_id"] as? String)?.lowercased() ?? ""
        guard intermediateWs == ws2IdStr.lowercased() else {
            throw Failure("intermediate tab transition workspace mismatch: got \(intermediateWs), expected \(ws2IdStr)")
        }
        let intermediateTabFrom = intermediateTab["from_id"] as? String ?? ""
        let intermediateTabTo = intermediateTab["to_id"] as? String ?? ""
        guard intermediateTabFrom == expectedTab1Id, intermediateTabTo == expectedTab0Id else {
            throw Failure("intermediate tab transition was \(intermediateTabFrom) -> \(intermediateTabTo), expected \(expectedTab1Id) -> \(expectedTab0Id)")
        }

        let finalWs = (finalTab["workspace_id"] as? String)?.lowercased() ?? ""
        guard finalWs == ws2IdStr.lowercased() else {
            throw Failure("final tab transition workspace mismatch: got \(finalWs), expected \(ws2IdStr)")
        }
        let finalTabFrom = finalTab["from_id"] as? String ?? ""
        let finalTabTo = finalTab["to_id"] as? String ?? ""
        guard finalTabFrom == expectedTab0Id, finalTabTo == expectedTab1Id else {
            throw Failure("final tab transition was \(finalTabFrom) -> \(finalTabTo), expected \(expectedTab0Id) -> \(expectedTab1Id)")
        }

        guard let tsTab0 = intermediateTab["timestamp"] as? Double,
              let tsTab1 = finalTab["timestamp"] as? Double else {
            throw Failure("missing timestamps on recorded tab transitions")
        }
        guard tsTab1 >= tsTab0 else {
            throw Failure("app-side tab transition timestamp order invalid (ts0=\(tsTab0), ts1=\(tsTab1))")
        }
        let tabTransitionIntervalMs = (tsTab1 - tsTab0) * 1000.0
        guard tabTransitionIntervalMs < 140.0 else {
            throw Failure("app-side tab transition interval exceeded race window: \(tabTransitionIntervalMs)ms (expected < 140ms)")
        }

        // Verify Tab 1 accessibility state indicates selection
        let selectedTab1 = d.wait(for: {
            guard let tab1Elem = d.tabElement(index: 1) else { return false }
            let val = d.attribute(tab1Elem, kAXValueAttribute) as NSNumber?
            return val?.intValue == 1
        }, timeout: 2.0)
        guard selectedTab1 else {
            let v = (d.tabElement(index: 1).flatMap { d.attribute($0, kAXValueAttribute) as NSNumber? })?.intValue ?? -1
            let v0 = (d.tabElement(index: 0).flatMap { d.attribute($0, kAXValueAttribute) as NSNumber? })?.intValue ?? -1
            let onScreen = d.onScreenWindowNumbers()
            let focus = d.debugFocusState()
            throw Failure("tab-1 AX value is \(v), tab-0 AX value is \(v0), onScreen: \(onScreen), focus: \(focus), expected 1 (selected)")
        }

        // Verify unassisted keyboard typing routes to Tab 1
        try d.run("tty > \(d.path("ws2_rapid_tab.txt"))")
        let rapidTabTTY = try d.file("ws2_rapid_tab.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard rapidTabTTY == ws2_tab1 else {
            throw Failure("rapid tab transition failed to route unassisted input to Tab 1 (got: \(rapidTabTTY), expected: \(ws2_tab1))")
        }
    }),
    ("workspace-frame-sync", "workspace switch inherits departing window frame when enabled and preserves independent frames when disabled", { d in
        // Clean start with pill style config
        d.quit()
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let wsDir = appSupport.appendingPathComponent(d.bundleID).appendingPathComponent("Workspaces")
            try? FileManager.default.removeItem(at: wsDir)
        }
        try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\ntab-style = pill\n")
        d.setPosition(CGPoint(x: 50, y: 50))
        d.setSize(CGSize(width: 600, height: 400))
        d.focus()
        usleep(1_000_000)

        // Capture initial Default workspace ID and Window A1
        let wsListInitial = try d.workspaceList()
        guard let wsAInfo = wsListInitial.first(where: { ($0["name"] as? String) == "Default" }),
              let wsAId = wsAInfo["id"] as? String else {
            throw Failure("Default workspace record not found")
        }
        guard (wsListInitial.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased() else {
            throw Failure("Default workspace is not active initially (list: \(wsListInitial))")
        }
        guard let initialFrameA1 = d.windowFrame() else {
            throw Failure("no window frame discovered for initial window in Default workspace")
        }
        guard let winA1 = d.activeWindow(),
              let idA1 = d.windowID(for: winA1) else {
            throw Failure("active window A1 or its ID not found")
        }

        // Create second window A2 in Default workspace via Cmd+N (multiple groups in Workspace A)
        d.key(Key.n, .maskCommand)
        guard d.wait(for: { d.onScreenWindowNumbers().count == 2 }, timeout: 5) else {
            throw Failure("second window A2 failed to appear after Cmd+N")
        }
        guard let winA2 = d.windows().first(where: { d.windowID(for: $0) != idA1 }),
              let idA2 = d.windowID(for: winA2) else {
            throw Failure("second window A2 AXUIElement or its ID not found")
        }
        d.setPosition(CGPoint(x: 700, y: 50), for: winA2)
        d.setSize(CGSize(width: 550, height: 380), for: winA2)
        usleep(500_000)
        guard let initialFrameA2 = d.windowFrame(winA2) else {
            throw Failure("could not read initial frame for window A2")
        }

        let liveWin: (CGWindowID) throws -> AXUIElement = { wid in
            guard let found = d.windows().first(where: { d.windowID(for: $0) == wid }) else {
                throw Failure("live window element not found for window ID \(wid)")
            }
            return found
        }

        // Re-focus Window A1 to establish it as the departing active window
        try d.click(at: CGPoint(x: 250, y: 150))
        usleep(600_000)
        guard let activeFrame = d.windowFrame(), abs(activeFrame.origin.x - 50) < 15 else {
            throw Failure("Window A1 was not active after click (expected x=50, got: \(String(describing: d.windowFrame())))")
        }
        let allWinA = d.onScreenWindowNumbers()
        guard allWinA.count == 2 else {
            throw Failure("expected 2 on-screen windows in Workspace A, found \(allWinA.count)")
        }

        // Create Workspace 2 via real mouse click on Workspace Pill of Window A1
        try d.clickWorkspacePill(in: try liveWin(idA1))
        try d.clickOpenMenuItem(titled: "New Workspace")
        guard d.wait(for: { d.button(titled: "Create") != nil }, timeout: 5) else {
            throw Failure("New Project Workspace alert dialog did not appear")
        }
        usleep(300_000)
        try d.clickButton(titled: "Create")
        guard d.wait(for: { d.button(titled: "Create") == nil }, timeout: 5) else {
            throw Failure("New Project Workspace alert was not dismissed")
        }
        usleep(1_500_000)

        // Verify Workspace 2 transition and identity
        let wsListAfterCreate = try d.workspaceList()
        guard let ws2Info = wsListAfterCreate.first(where: { ($0["name"] as? String) != "Default" }),
              let ws2Name = ws2Info["name"] as? String,
              let ws2Id = ws2Info["id"] as? String else {
            throw Failure("Workspace 2 record not found after creation")
        }
        guard (wsListAfterCreate.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == ws2Id.lowercased() else {
            throw Failure("active workspace did not transition to Workspace 2 after creation (list: \(wsListAfterCreate))")
        }

        // Verify Window B is completely disjoint from Workspace A windows
        let onScreenB = d.onScreenWindowNumbers()
        guard onScreenB.count == 1 && onScreenB.intersection(allWinA).isEmpty else {
            throw Failure("Window B on-screen set is not disjoint from Workspace A windows (B=\(onScreenB), A=\(allWinA))")
        }
        guard let idB = onScreenB.first else {
            throw Failure("could not resolve window ID for Window B")
        }

        // Give Workspace 2 window a distinctly different frame
        let winBInit = try liveWin(idB)
        d.setPosition(CGPoint(x: 200, y: 150), for: winBInit)
        d.setSize(CGSize(width: 680, height: 440), for: winBInit)
        usleep(500_000)
        guard let initialFrameB = d.windowFrame(winBInit) else {
            throw Failure("no window frame for Workspace 2")
        }
        guard abs(initialFrameB.origin.x - initialFrameA1.origin.x) > 40 ||
              abs(initialFrameB.size.width - initialFrameA1.size.width) > 40 else {
            throw Failure("Workspace A and B frames are not distinct (A: \(initialFrameA1), B: \(initialFrameB))")
        }

        // 1. With syncWindowFrame == false (default): switching workspaces preserves independent frames
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        usleep(1_500_000)

        // Destination workspace assertion
        let wsCheck1 = try d.workspaceList()
        guard (wsCheck1.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased() else {
            throw Failure("active workspace did not switch to Default (list: \(wsCheck1))")
        }
        // Distinct on-screen window assertion (must match allWinA, disjoint from Window B)
        guard d.onScreenWindowNumbers() == allWinA else {
            throw Failure("on-screen windows in Default did not match allWinA: \(d.onScreenWindowNumbers()) vs \(allWinA)")
        }
        let curWinA1 = try liveWin(idA1)
        let curWinA2 = try liveWin(idA2)
        guard let frameA1Returned = d.windowFrame(curWinA1) else {
            throw Failure("no window frame for window A1 after returning to Default workspace")
        }
        guard abs(frameA1Returned.origin.x - initialFrameA1.origin.x) < 5 &&
              abs(frameA1Returned.origin.y - initialFrameA1.origin.y) < 5 &&
              abs(frameA1Returned.size.width - initialFrameA1.size.width) < 5 &&
              abs(frameA1Returned.size.height - initialFrameA1.size.height) < 5 else {
            throw Failure("Default workspace window A1 frame changed while sync was disabled (expected: \(initialFrameA1), got: \(frameA1Returned))")
        }
        guard let frameA2Returned = d.windowFrame(curWinA2) else {
            throw Failure("no window frame for inactive sibling window A2 after returning to Default workspace")
        }
        guard abs(frameA2Returned.origin.x - initialFrameA2.origin.x) < 5 &&
              abs(frameA2Returned.origin.y - initialFrameA2.origin.y) < 5 &&
              abs(frameA2Returned.size.width - initialFrameA2.size.width) < 5 &&
              abs(frameA2Returned.size.height - initialFrameA2.size.height) < 5 else {
            throw Failure("Default workspace inactive sibling window A2 frame changed while sync was disabled (expected: \(initialFrameA2), got: \(frameA2Returned))")
        }

        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: ws2Name)
        usleep(1_500_000)

        // Destination workspace assertion
        let wsCheck2 = try d.workspaceList()
        guard (wsCheck2.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == ws2Id.lowercased() else {
            throw Failure("active workspace did not switch to Workspace 2 (list: \(wsCheck2))")
        }
        // Distinct on-screen window assertion (must match onScreenB, disjoint from allWinA)
        guard d.onScreenWindowNumbers() == onScreenB else {
            throw Failure("on-screen window in Workspace 2 did not match onScreenB: \(d.onScreenWindowNumbers()) vs \(onScreenB)")
        }
        let curWinB = try liveWin(idB)
        guard let frameBReturned = d.windowFrame(curWinB) else {
            throw Failure("no window frame after returning to Workspace 2")
        }
        guard abs(frameBReturned.origin.x - initialFrameB.origin.x) < 5 &&
              abs(frameBReturned.origin.y - initialFrameB.origin.y) < 5 &&
              abs(frameBReturned.size.width - initialFrameB.size.width) < 5 &&
              abs(frameBReturned.size.height - initialFrameB.size.height) < 5 else {
            throw Failure("Workspace 2 frame changed while sync was disabled (expected: \(initialFrameB), got: \(frameBReturned))")
        }

        // 2. Enable workspace-sync-window-frame through Settings UI
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("Settings dialog failed to open")
        }
        d.key(Key.two, .maskCommand) // switch to Terminal Settings tab
        usleep(300_000)

        // Focus search and filter to sync
        if let search = d.descendants(of: d.element(withIdentifier: "TerminalSettingsDialog")!, role: kAXTextFieldRole).first {
            d.press(search)
            try d.type("sync")
            usleep(300_000)
        }
        // Click list row to transfer responder and press Space
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
            throw Failure("Space did not toggle workspace-sync-window-frame")
        }

        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after enabling sync")
        }

        // Verify config on disk contains setting (fail-closed read)
        let syncConfigLines = try String(contentsOfFile: d.path("config"), encoding: .utf8)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard syncConfigLines.contains("workspace-sync-window-frame = true") else {
            throw Failure("config file missing workspace-sync-window-frame = true")
        }

        // Capture departing Workspace B window geometry before switch
        d.setPosition(CGPoint(x: 180, y: 120))
        d.setSize(CGSize(width: 720, height: 460))
        usleep(500_000)
        guard let departingFrameB = d.windowFrame() else {
            throw Failure("could not read departing Workspace B frame")
        }

        // Switch to Default workspace via UI
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        usleep(1_500_000)

        // Assert destination workspace transition to Default
        let wsCheck3 = try d.workspaceList()
        guard (wsCheck3.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased() else {
            throw Failure("active workspace did not transition to Default after switch from B (list: \(wsCheck3))")
        }
        // Assert on-screen window set is allWinA (disjoint from Window B)
        guard d.onScreenWindowNumbers() == allWinA else {
            throw Failure("on-screen windows in Default did not match allWinA: \(d.onScreenWindowNumbers()) vs \(allWinA)")
        }

        // Verify active Default workspace window inherited departing Workspace B frame!
        guard let inheritedFrameA = d.windowFrame() else {
            throw Failure("no window frame after switching to Default with sync enabled")
        }
        guard abs(inheritedFrameA.origin.x - departingFrameB.origin.x) < 5 &&
              abs(inheritedFrameA.origin.y - departingFrameB.origin.y) < 5 &&
              abs(inheritedFrameA.size.width - departingFrameB.size.width) < 5 &&
              abs(inheritedFrameA.size.height - departingFrameB.size.height) < 5 else {
            throw Failure("Default workspace active window did not inherit departing frame (departing B: \(departingFrameB), inherited A: \(inheritedFrameA))")
        }

        // Resize active Window A to a new distinct frame while second window remains untouched
        d.setPosition(CGPoint(x: 80, y: 80))
        d.setSize(CGSize(width: 780, height: 490))
        usleep(500_000)
        guard let departingFrameA = d.windowFrame() else {
            throw Failure("could not read departing Window A frame")
        }

        // Switch back to Workspace 2: verify Window B inherits departing active Window A frame (not arbitrary A1)
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: ws2Name)
        usleep(1_500_000)

        // Assert destination workspace transition to Workspace 2
        let wsCheck4 = try d.workspaceList()
        guard (wsCheck4.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == ws2Id.lowercased() else {
            throw Failure("active workspace did not transition to Workspace 2 after switch from A (list: \(wsCheck4))")
        }
        // Assert on-screen window set is onScreenB (disjoint from allWinA)
        guard d.onScreenWindowNumbers() == onScreenB else {
            throw Failure("on-screen window in Workspace 2 did not match onScreenB: \(d.onScreenWindowNumbers()) vs \(onScreenB)")
        }

        guard let inheritedFrameB = d.windowFrame() else {
            throw Failure("no window frame after switching to Workspace 2 with sync enabled")
        }
        guard abs(inheritedFrameB.origin.x - departingFrameA.origin.x) < 5 &&
              abs(inheritedFrameB.origin.y - departingFrameA.origin.y) < 5 &&
              abs(inheritedFrameB.size.width - departingFrameA.size.width) < 5 &&
              abs(inheritedFrameB.size.height - departingFrameA.size.height) < 5 else {
            throw Failure("Workspace 2 window did not inherit departing frame (departing A: \(departingFrameA), inherited B: \(inheritedFrameB))")
        }

        // 3. Reset workspace-sync-window-frame through Settings UI
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("Settings dialog failed to reopen for reset")
        }
        d.key(Key.two, .maskCommand)
        usleep(300_000)
        d.key(Key.d)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return val == "setting_reset_success: workspace-sync-window-frame" ||
                   val.contains("Reset to default: workspace-sync-window-frame")
        }, timeout: 5) else {
            throw Failure("key 'd' did not reset workspace-sync-window-frame")
        }
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog after reset")
        }

        // Verify config on disk no longer contains setting (fail-closed read)
        let resetConfigLines = try String(contentsOfFile: d.path("config"), encoding: .utf8)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !resetConfigLines.contains(where: { $0.hasPrefix("workspace-sync-window-frame") || $0.hasPrefix("workspace-inherit-window-frame") }) else {
            throw Failure("config file still contained override after reset")
        }

        // Verify independent frames survive after reset across an A -> B -> A cycle
        // 1. In Workspace 2, establish explicit geometry for Window B
        let resetWinB = try liveWin(idB)
        d.setPosition(CGPoint(x: 320, y: 220), for: resetWinB)
        d.setSize(CGSize(width: 520, height: 360), for: resetWinB)
        usleep(500_000)
        guard let expectedResetFrameB = d.windowFrame(resetWinB) else { throw Failure("no frame B after reset") }

        // Switch to Default workspace
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        usleep(1_500_000)

        // Assert destination workspace transition to Default
        let wsCheck5 = try d.workspaceList()
        guard (wsCheck5.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased() else {
            throw Failure("active workspace did not transition to Default after reset (list: \(wsCheck5))")
        }
        // Assert on-screen windows are allWinA
        guard d.onScreenWindowNumbers() == allWinA else {
            throw Failure("on-screen windows did not match allWinA after reset")
        }

        // Capture inactive sibling full frame before switch
        let postResetActiveWinA = try liveWin(idA2)
        let postResetInactiveWinA = try liveWin(idA1)
        guard let expectedResetInactiveFrameA = d.windowFrame(postResetInactiveWinA) else {
            throw Failure("could not read inactive sibling window frame in Default workspace after reset")
        }

        // Resize active Window A to a new distinct rectangle while inactive Window A1 is untouched
        d.setPosition(CGPoint(x: 90, y: 90), for: postResetActiveWinA)
        d.setSize(CGSize(width: 750, height: 470), for: postResetActiveWinA)
        usleep(500_000)
        guard let departingFrameAfterResetA = d.windowFrame(postResetActiveWinA) else {
            throw Failure("could not read frame for active Window A after post-reset resize")
        }

        // Switch to Workspace 2: verify Window B strictly retains expectedResetFrameB in all 4 dimensions
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: ws2Name)
        usleep(1_500_000)

        let wsCheck6 = try d.workspaceList()
        guard (wsCheck6.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == ws2Id.lowercased() else {
            throw Failure("active workspace did not transition to Workspace 2 in post-reset check (list: \(wsCheck6))")
        }
        guard d.onScreenWindowNumbers() == onScreenB else {
            throw Failure("on-screen windows did not match onScreenB in post-reset check: \(d.onScreenWindowNumbers()) vs \(onScreenB)")
        }

        let postResetReturnWinB = try liveWin(idB)
        guard let actualFrameBAfterSwitch = d.windowFrame(postResetReturnWinB) else {
            throw Failure("no frame for Window B after returning to Workspace 2 in post-reset check")
        }
        guard abs(actualFrameBAfterSwitch.origin.x - expectedResetFrameB.origin.x) < 5 &&
              abs(actualFrameBAfterSwitch.origin.y - expectedResetFrameB.origin.y) < 5 &&
              abs(actualFrameBAfterSwitch.size.width - expectedResetFrameB.size.width) < 5 &&
              abs(actualFrameBAfterSwitch.size.height - expectedResetFrameB.size.height) < 5 else {
            throw Failure("Window B frame was not preserved with sync disabled (expected: \(expectedResetFrameB), got: \(actualFrameBAfterSwitch), departing A was: \(departingFrameAfterResetA))")
        }

        // Now resize Window B to another new rectangle in Workspace 2
        d.setPosition(CGPoint(x: 350, y: 250), for: postResetReturnWinB)
        d.setSize(CGSize(width: 580, height: 390), for: postResetReturnWinB)
        usleep(500_000)
        guard let departingFrameAfterResetB = d.windowFrame(postResetReturnWinB) else {
            throw Failure("could not read frame for Window B after second post-reset resize")
        }

        // Switch back to Default workspace: verify both active and inactive windows strictly preserve their geometry
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        usleep(1_500_000)

        let wsCheck7 = try d.workspaceList()
        guard (wsCheck7.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased() else {
            throw Failure("active workspace did not transition to Default in final post-reset return (list: \(wsCheck7))")
        }
        guard d.onScreenWindowNumbers() == allWinA else {
            throw Failure("on-screen windows did not match allWinA in final post-reset return: \(d.onScreenWindowNumbers()) vs \(allWinA)")
        }

        let finalActiveWinA = try liveWin(idA2)
        let finalInactiveWinA = try liveWin(idA1)
        guard let actualFrameActiveFinal = d.windowFrame(finalActiveWinA) else {
            throw Failure("could not read frame for active Window A in final post-reset return")
        }
        guard abs(actualFrameActiveFinal.origin.x - departingFrameAfterResetA.origin.x) < 5 &&
              abs(actualFrameActiveFinal.origin.y - departingFrameAfterResetA.origin.y) < 5 &&
              abs(actualFrameActiveFinal.size.width - departingFrameAfterResetA.size.width) < 5 &&
              abs(actualFrameActiveFinal.size.height - departingFrameAfterResetA.size.height) < 5 else {
            throw Failure("Active Window A frame was not preserved after return switch with sync disabled (expected: \(departingFrameAfterResetA), got: \(actualFrameActiveFinal), departing B was: \(departingFrameAfterResetB))")
        }

        guard let actualFrameInactiveFinal = d.windowFrame(finalInactiveWinA) else {
            throw Failure("could not read frame for inactive sibling Window A in final post-reset return")
        }
        guard abs(actualFrameInactiveFinal.origin.x - expectedResetInactiveFrameA.origin.x) < 5 &&
              abs(actualFrameInactiveFinal.origin.y - expectedResetInactiveFrameA.origin.y) < 5 &&
              abs(actualFrameInactiveFinal.size.width - expectedResetInactiveFrameA.size.width) < 5 &&
              abs(actualFrameInactiveFinal.size.height - expectedResetInactiveFrameA.size.height) < 5 else {
            throw Failure("Inactive sibling Window A frame was not preserved after return switch with sync disabled (expected: \(expectedResetInactiveFrameA), got: \(actualFrameInactiveFinal))")
        }

        // Verify terminal unassisted keyboard delivery
        try d.run("echo 'frame_sync_ok' > \(d.path("frame_sync_witness"))")
        try d.expect("frame_sync_witness", "frame_sync_ok\n", "terminal keyboard input after frame sync journey")
    }),
    ("tab-status-click", "pill tab status dots transition across working/waiting/done and reset to idle/dim on real mouse click with unassisted focus recovery", { d in
        try runTabStatusClickScenario(d)
    }),
    ("kitty-icat", "kitten icat detects Tako and displays an image without corrupting terminal input", { d in
        try runKittyIcatScenario(d)
    }),
    ("terminal-dialogs", "Rename Tab, multi-window Quit confirmation, and Connect AI Agents use in-terminal TerminalDialogView and recover unassisted focus", { d in
        try runTerminalDialogsScenario(d)
    }),
    ("tab-drag-reorder", "dragging a pill tab across another tab reorders tabs in custom tab bar and tree and recovers unassisted focus", { d in
        try runTabDragReorderScenario(d)
    }),
    ("safe-paste-guard", "multiline Cmd+V at prompt opens Safe Paste confirmation, Cancel blocks execution, Paste runs lines, and recovers unassisted focus", { d in
        try runSafePasteGuardScenario(d)
    }),
    ("sidebar-interaction", "Session Sidebar collapses/expands subagents, filters tabs, switches active session on click, and recovers unassisted focus", { d in
        try runSidebarInteractionScenario(d)
    }),
    ("overview-selection", "Pane Overview filters cards, clears empty state, jumps to selected pane on Return, and recovers unassisted focus", { d in
        try runOverviewSelectionScenario(d)
    }),
    ("attention-jump", "Next Attention and Go Back to Previous Pane navigate unseen attention across tabs and recover unassisted focus", { d in
        try runAttentionJumpScenario(d)
    }),
    ("input-takeover-confirm", "InputOwnershipHeaderView Take Over, Hand Back, and unlock work end-to-end", { d in
        try runInputTakeoverConfirmScenario(d)
    }),
]

// MARK: - Main

@main
struct TakoE2E {
    static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let appPath = args.first else {
        print("usage: tako-e2e <Tako.app> [scenario ...]")
        for s in scenarios { print("  \(s.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.why)") }
        exit(2)
    }
    guard AXIsProcessTrusted() else {
        print("FAIL: this process has no Accessibility permission, so it can neither post keys nor read windows")
        exit(1)
    }
    let wanted = Set(args.dropFirst())
    // Scenarios that need a build with the session runtime run only when named,
    // from scripts/e2e-persist.sh: never as part of the default set.
    let persistenceOnly: Set<String> = ["persist-live", "persist-gone", "persist-close", "persist-cancel", "persist-close-asks", "persist-close-quit", "persist-second-owner", "persist-reflow"]
    let explicitOnly = persistenceOnly.union(["kitty-icat"])
    // A misspelt name must not pass as a run of nothing.
    let unknown = wanted.subtracting(scenarios.map(\.name))
    if !unknown.isEmpty {
        print("FAIL: no scenario named \(unknown.sorted().joined(separator: ", "))")
        exit(2)
    }
    let previouslyFront = NSWorkspace.shared.frontmostApplication
    var failed = 0
    if !wanted.isDisjoint(with: persistenceOnly) {
        let helper = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Helpers/zmx").path
        guard FileManager.default.isExecutableFile(atPath: helper),
              ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] != nil else {
            print("FAIL: persistence scenarios need scripts/e2e-persist.sh (an app with its session runtime and an isolated session home)")
            exit(2)
        }
    }
    for scenario in scenarios where (wanted.isEmpty && !explicitOnly.contains(scenario.name)) || wanted.contains(scenario.name) {
        // A fresh app per scenario: one that failed half way must not leave a
        // split, a zoom or a hung command behind for the next.
        do {
            let driver = try Driver(app: URL(fileURLWithPath: appPath))
            defer { driver.quit() }
            do {
                try driver.launch()
                try scenario.body(driver)
                print("ok    \(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(scenario.why)")
                // A failed scenario keeps its files, which are the evidence.
                try? FileManager.default.removeItem(at: driver.work)
            } catch {
                failed += 1
                print("FAIL  \(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(error)")
            }
        } catch {
            failed += 1
            print("FAIL  \(scenario.name): \(error)")
        }
    }
    print(failed == 0 ? "tako e2e: ok" : "tako e2e: \(failed) FAILED")
    if let previouslyFront, !previouslyFront.isTerminated, let bundle = previouslyFront.bundleURL {
        // activate() from a process that is not itself in front is only a
        // request; open is how the focus reliably goes back.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path]
        try? open.run()
        open.waitUntilExit()
        previouslyFront.activate()
    }
    exit(failed == 0 ? 0 : 1)

    }
}

/// Two tabs, three panes, made through takoctl, then left long enough to be
/// recorded.
func crashLayoutSetup(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "window-save-state = always\n")
    usleep(500_000)
    // Start from one window, whatever an earlier run left.
    // Right after launch fish can still be starting and drop what is typed:
    // ask again until it answers, so the scenario starts from a shell that
    // is listening.
    var listening = false
    for _ in 0..<5 where !listening {
        try d.run("takoctl tree --json > \(d.path("start"))")
        listening = (try? d.file("start", timeout: 5)) != nil
        if !listening { usleep(300_000) }
    }
    guard listening else { throw Failure("the shell never took input: [\(d.screenText().suffix(400))]") }
    usleep(500_000)
    let out = d.work.path
    try """
    takoctl split right > /dev/null || exit 1
    takoctl tab-new --no-select > /dev/null || exit 1
    echo done > \(out)/made
    """.write(toFile: d.path("make.sh"), atomically: true, encoding: .utf8)
    try d.run("sh \(d.path("make.sh"))")
    guard (try? d.file("made", timeout: 15)) != nil else {
        throw Failure("the layout was not made; screen: [\(d.screenText().suffix(600))]")
    }
    usleep(2_000_000)
}

func crashLayoutCount(_ d: Driver, _ name: String) throws -> (windows: Int, tabs: Int, panes: Int) {
    try d.run("takoctl tree --json > \(d.path(name))")
    let json = try d.file(name)
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return (0, 0, 0) }
    let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
    return (windows.count, tabs.count, tabs.reduce(0) { $0 + (($1["panes"] as? [Any])?.count ?? 0) })
}

/// Nothing saved from an earlier run: neither AppKit's state nor the journal.
func forgetLayout(_ d: Driver) {
    let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
    guard bundle != "com.tako-core.terminal" else {
        fputs("Safety error: forgetLayout refused to delete state for production bundle 'com.tako-core.terminal'\n", stderr)
        return
    }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    // Newer macOS keeps saved windows where only the script finds them.
    let forget = Process()
    forget.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    forget.arguments = ["python3", "scripts/e2e/forget-saved-state.py", bundle]
    try? forget.run()
    forget.waitUntilExit()
    try? FileManager.default.removeItem(at: library.appendingPathComponent("Application Support/\(bundle)/layout"))
}
