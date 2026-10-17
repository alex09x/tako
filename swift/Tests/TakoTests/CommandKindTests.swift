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
import Testing
@testable import Tako

@Suite
struct CommandKindTests {
    private func kind(_ line: String, quiet: Set<String> = [], busy: Set<String> = []) -> Tako.CommandKind {
        Tako.CommandKind.classify(line, quiet: quiet, busy: busy)
    }

    @Test func jobsThatFinishAreBatch() {
        for line in ["cargo test", "make -j8", "rsync -a src/ dst/", "python3 train.py", "npm test",
                     "tail -n 50 app.log", "ssh host make", "ssh -p 2222 host uptime", "docker build .",
                     "psql -c 'select 1' db", "redis-cli -h cache GET key", "sqlite3 app.db 'select 1'",
                     "git log --oneline -5", "bash deploy.sh", "node build.js", "go run ."] {
            #expect(kind(line) == .batch, "\(line)")
        }
    }

    @Test func programsTheUserIsInsideAreQuiet() {
        for line in ["vim notes.md", "less app.log", "htop", "man ls", "python3", "python -i", "node",
                     "psql mydb", "redis-cli -h cache", "sqlite3 app.db", "claude", "codex resume",
                     "sudo htop", "TERM=xterm-256color nvim"] {
            #expect(kind(line) == .quiet, "\(line)")
        }
    }

    @Test func streamsAndServersAreQuiet() {
        for line in ["tail -f app.log", "tail -F app.log", "tail -fn100 app.log", "tail --follow=name x",
                     "journalctl -fu nginx", "docker logs -f api", "kubectl logs -f pod/api",
                     "docker compose up", "npm run dev", "pnpm dev", "yarn watch:css", "bun run start",
                     "npx vite", "next dev", "cargo watch -x test", "python -m http.server 8000",
                     "python manage.py runserver", "rails s", "bundle exec jekyll serve", "ping 1.1.1.1",
                     "tail -f a.log | grep ERROR", "tsc --watch", "vitest", "php -S localhost:8000"] {
            #expect(kind(line) == .quiet, "\(line)")
        }
        #expect(kind("docker compose up -d") == .batch)
        #expect(kind("vitest run") == .batch)
    }

    @Test func connectionsAndShells() {
        #expect(kind("ssh alex@ram11") == .connection)
        #expect(kind("ssh -i ~/.ssh/key -p 22 host") == .connection)
        #expect(kind("cd ~/src && ssh host") == .connection)
        #expect(kind("mosh host") == .connection)
        #expect(kind("bash") == .shell)
        #expect(kind("fish -l") == .shell)
        #expect(kind("sudo -i") == .shell)
        #expect(kind("tmux attach -t work") == .shell)
        #expect(kind("docker exec -it api bash") == .shell)
    }

    @Test func theUsersListsWin() {
        #expect(kind("my-repl --port 1", quiet: ["my-repl"]) == .quiet)
        #expect(kind("ssh host", busy: ["ssh"]) == .batch)
        #expect(kind("/usr/local/bin/my-repl", quiet: ["my-repl"]) == .quiet)
    }

    @Test func quotesAndSeparatorsAreShellSyntax() {
        #expect(kind("echo 'tail -f x'") == .batch)
        #expect(kind("make; tail -f build.log") == .quiet)
        #expect(Tako.ShellLine.segments(of: #"git commit -m "a | b" && vim x"#)
            == [["git", "commit", "-m", "a | b"], ["vim", "x"]])
    }

    @Test func whatEndingIsAFailure() {
        #expect(Tako.CommandKind.batch.fails(1))
        #expect(Tako.CommandKind.batch.fails(130))
        #expect(!Tako.CommandKind.quiet.fails(0))
        #expect(!Tako.CommandKind.quiet.fails(130))
        #expect(Tako.CommandKind.quiet.fails(1))
        #expect(Tako.CommandKind.connection.fails(255))
        #expect(!Tako.CommandKind.connection.fails(1))
        #expect(!Tako.CommandKind.shell.fails(1))
    }
}

@Suite @MainActor
struct CrabCommandKindTests {
    private func tracker(_ now: @escaping () -> Date) -> Tako.CrabTracker { Tako.CrabTracker(now: now) }

    @Test func aQuietCommandNeverShowsWorking() {
        var now = Date(timeIntervalSince1970: 0)
        let crab = tracker { now }
        crab.commandStarted(kind: .connection)
        #expect(crab.paneStatus == .idle)
        now = now.addingTimeInterval(600)
        crab.tick()
        #expect(crab.state == .idle)
        #expect(crab.paneStatus == .idle)
        #expect(crab.elapsed == nil)
    }

    @Test func leavingAQuietProgramIsNotDone() {
        var now = Date(timeIntervalSince1970: 0)
        let crab = tracker { now }
        crab.commandStarted(kind: .quiet)
        now = now.addingTimeInterval(600)
        crab.commandEnded(exitCode: 0)
        #expect(crab.state == .idle)
        #expect(crab.paneStatus == .idle)
        #expect(!crab.unread)

        crab.commandStarted(kind: .quiet)
        crab.commandEnded(exitCode: 130)
        #expect(crab.paneStatus == .idle)
    }

    @Test func aDroppedConnectionAndACrashedServerFail() {
        let crab = tracker { Date(timeIntervalSince1970: 0) }
        crab.commandStarted(kind: .connection)
        crab.commandEnded(exitCode: 255)
        #expect(crab.paneStatus == .error)
        #expect(crab.unread)

        crab.focused()
        crab.commandStarted(kind: .connection)
        crab.commandEnded(exitCode: 1)
        #expect(crab.paneStatus == .idle)

        crab.commandStarted(kind: .quiet)
        crab.commandEnded(exitCode: 1)
        #expect(crab.paneStatus == .error)
    }

    @Test func aJobThatTurnsFullScreenGoesQuiet() {
        var now = Date(timeIntervalSince1970: 0)
        var alternate = false
        let crab = tracker { now }
        crab.commandStarted(kind: .batch, isAlternateScreen: { alternate })
        now = now.addingTimeInterval(5)
        crab.tick()
        #expect(crab.state == .running)
        alternate = true
        crab.tick()
        #expect(crab.state == .idle)
        #expect(crab.paneStatus == .idle)
        #expect(crab.commandKind == .quiet)
        crab.commandEnded(exitCode: 0)
        #expect(crab.state == .idle)
    }

    @Test func anAgentsOwnStatusStillWinsAndKeepsItsClock() {
        var now = Date(timeIntervalSince1970: 0)
        let crab = tracker { now }
        crab.commandStarted(kind: .quiet)
        crab.setStatus(.working, text: "Thinking")
        now = now.addingTimeInterval(10)
        crab.tick()
        #expect(crab.paneStatus == .working)
        #expect(crab.elapsed != nil)
    }

    @Test func aBatchJobStillWorksAndFinishes() {
        var now = Date(timeIntervalSince1970: 0)
        let crab = tracker { now }
        crab.commandStarted(kind: .batch)
        now = now.addingTimeInterval(5)
        crab.tick()
        #expect(crab.state == .running)
        crab.commandEnded(exitCode: 0)
        #expect(crab.state == .succeeded)
    }
}
