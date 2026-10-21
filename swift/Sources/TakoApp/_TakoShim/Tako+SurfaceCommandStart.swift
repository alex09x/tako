/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension Tako.SurfaceView {
    /// The shell marked a command's start (OSC 133;C). `line` is the
    /// command line it sent or the screen showed; empty when neither did.
    func shellStartedCommand(_ line: String) {
        crab.isFocused = isBeingLookedAt
        crab.commandStarted(kind: commandKind(of: line), probe: liveProbe(for: line))
        commandStarted()
        if line.isEmpty { identifyUnreportedCommand() }
    }

    /// A shell that says nothing of what it runs -- a fish started before
    /// its integration sent the line, which a persistent session keeps for
    /// weeks -- marks a start with no command line, and every such command
    /// was a job: `tail -f` and ssh spun as working. The process in front of
    /// the shell says what it is once the shell has handed it the terminal,
    /// and a quiet one goes live before a job would show as working.
    func identifyUnreportedCommand(tries: Int = 4, every delay: TimeInterval = 0.5) {
        guard tries > 0, let started = commandStartedAt else { return }
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.commandStartedAt == started else { return }
                guard let line = self.frontCommandProbe?() ?? self.frontCommand() else {
                    self.identifyUnreportedCommand(tries: tries - 1, every: delay)
                    return
                }
                let kind = self.commandKind(of: line)
                guard kind != .batch else { return }
                self.crab.commandIdentified(as: kind, probe: self.liveProbe(for: line))
                Tako.TabBarController.refreshAll()
            }
        }
    }
}
