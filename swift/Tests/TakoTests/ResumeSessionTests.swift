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

@Suite @MainActor struct ResumeSessionTests {

    @Test func testSecretSanitization() {
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/alex",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "OPENAI_API_KEY": "sk-secret123",
            "GITHUB_TOKEN": "ghp_secret456",
            "DB_PASSWORD": "mypassword",
            "SECRET_SALT": "xyz",
            "AUTH_BEARER": "bearer-token",
            "AWS_CREDENTIAL_FILE": "/path/to/creds",
            "PRIVATE_SIGNING_KEY": "pem-content",
            "ACCESS_ID": "id-999",
            "SOME_PASSWD": "12345",
        ]

        let sanitized = ResumeSessionStore.sanitizeEnvironment(env)
        #expect(sanitized["PATH"] == "/usr/bin:/bin")
        #expect(sanitized["HOME"] == "/Users/alex")
        #expect(sanitized["TERM"] == "xterm-256color")
        #expect(sanitized["LANG"] == "en_US.UTF-8")

        #expect(sanitized["OPENAI_API_KEY"] == nil)
        #expect(sanitized["GITHUB_TOKEN"] == nil)
        #expect(sanitized["DB_PASSWORD"] == nil)
        #expect(sanitized["SECRET_SALT"] == nil)
        #expect(sanitized["AUTH_BEARER"] == nil)
        #expect(sanitized["AWS_CREDENTIAL_FILE"] == nil)
        #expect(sanitized["PRIVATE_SIGNING_KEY"] == nil)
        #expect(sanitized["ACCESS_ID"] == nil)
        #expect(sanitized["SOME_PASSWD"] == nil)

        // Record constructor automatically sanitizes
        let record = ResumeSessionRecord(
            argv: ["claude", "--resume", "123"],
            cwd: "/tmp",
            env: env
        )
        #expect(record.env["OPENAI_API_KEY"] == nil)
        #expect(record.env["PATH"] == "/usr/bin:/bin")
    }

    @Test func testTrustStorePrefixApproval() {
        let userDefaultsSuite = "test.tako.resume.trust.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { defaults.removePersistentDomain(forName: userDefaultsSuite) }

        let trustStore = ResumeTrustStore(defaults: defaults)
        let cwd = "/Users/alex/project"

        #expect(!trustStore.isApproved(argv: ["claude", "--resume", "abc"], cwd: cwd))

        // Approve "claude"
        trustStore.approve(prefix: "claude", cwd: cwd)
        #expect(trustStore.isApproved(argv: ["claude", "--resume", "abc"], cwd: cwd))
        #expect(trustStore.isApproved(argv: ["claude"], cwd: cwd))

        // Different directory should not be approved
        #expect(!trustStore.isApproved(argv: ["claude", "--resume", "abc"], cwd: "/Users/alex/other"))

        // Different command should not be approved
        #expect(!trustStore.isApproved(argv: ["bash", "-c", "evil"], cwd: cwd))

        // Multi-word prefix approval
        trustStore.approve(prefix: "npm run dev", cwd: cwd)
        #expect(trustStore.isApproved(argv: ["npm", "run", "dev", "--port", "3000"], cwd: cwd))
        #expect(!trustStore.isApproved(argv: ["npm", "test"], cwd: cwd))

        // Revoke
        trustStore.revoke(prefix: "claude", cwd: cwd)
        #expect(!trustStore.isApproved(argv: ["claude", "--resume", "abc"], cwd: cwd))
        #expect(trustStore.isApproved(argv: ["npm", "run", "dev"], cwd: cwd))
    }

    @Test func testResumeSessionStorePersistence() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ResumeSessionStore(directory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pane1 = UUID()
        let pane2 = UUID()

        #expect(store.record(for: pane1) == nil)

        let record1 = ResumeSessionRecord(
            argv: ["gemini", "chat"],
            cwd: "/Users/alex/work",
            env: ["ENV_VAR": "val"]
        )
        store.set(record: record1, for: pane1)

        let retrieved1 = store.record(for: pane1)
        #expect(retrieved1 != nil)
        #expect(retrieved1?.argv == ["gemini", "chat"])
        #expect(retrieved1?.cwd == "/Users/alex/work")
        #expect(retrieved1?.env["ENV_VAR"] == "val")
        #expect(retrieved1?.isImported == false)

        // Clear pane1
        store.clear(for: pane1)
        #expect(store.record(for: pane1) == nil)

        // Test cleanup with removeAll(except:)
        store.set(record: record1, for: pane1)
        let record2 = ResumeSessionRecord(argv: ["codex"], cwd: "/tmp")
        store.set(record: record2, for: pane2)

        store.removeAll(except: [pane2])
        #expect(store.record(for: pane1) == nil)
        #expect(store.record(for: pane2) != nil)
    }

    @Test func testImportedSessionUntrusted() {
        let userDefaultsSuite = "test.tako.resume.imported.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { defaults.removePersistentDomain(forName: userDefaultsSuite) }

        let trustStore = ResumeTrustStore(defaults: defaults)
        let cwd = "/Users/alex/repo"
        trustStore.approve(prefix: "claude", cwd: cwd)

        let importedRecord = ResumeSessionRecord(
            argv: ["claude", "--resume", "xyz"],
            cwd: cwd,
            isImported: true
        )
        #expect(importedRecord.isImported == true)

        // Even though "claude" is approved in trustStore, imported sessions must never auto-run
        let canAutoRun = trustStore.isApproved(argv: importedRecord.argv, cwd: cwd) && !importedRecord.isImported
        #expect(!canAutoRun)

        let nativeRecord = ResumeSessionRecord(
            argv: ["claude", "--resume", "xyz"],
            cwd: cwd,
            isImported: false
        )
        let canNativeAutoRun = trustStore.isApproved(argv: nativeRecord.argv, cwd: cwd) && !nativeRecord.isImported
        #expect(canNativeAutoRun)
    }

    @Test func testShellQuoteAndMetacharacters() {
        // 1. Safe tokens remain unquoted
        #expect(ResumeSessionStore.shellQuote("echo") == "echo")
        #expect(ResumeSessionStore.shellQuote("/bin/ls") == "/bin/ls")
        #expect(ResumeSessionStore.shellQuote("--port=8080") == "--port=8080")
        #expect(ResumeSessionStore.shellQuote("foo_bar.txt") == "foo_bar.txt")

        // 2. Empty token is quoted
        #expect(ResumeSessionStore.shellQuote("") == "''")

        // 3. Tokens with whitespace or shell metacharacters are safely single-quoted
        #expect(ResumeSessionStore.shellQuote("hello world") == "'hello world'")
        #expect(ResumeSessionStore.shellQuote(";") == "';'")
        #expect(ResumeSessionStore.shellQuote("&&") == "'&&'")
        #expect(ResumeSessionStore.shellQuote("|") == "'|'")
        #expect(ResumeSessionStore.shellQuote("$HOME") == "'$HOME'")
        #expect(ResumeSessionStore.shellQuote("$(whoami)") == "'$(whoami)'")
        #expect(ResumeSessionStore.shellQuote("`id`") == "'`id`'")
        #expect(ResumeSessionStore.shellQuote(">out") == "'>out'")
        #expect(ResumeSessionStore.shellQuote("<in") == "'<in'")
        #expect(ResumeSessionStore.shellQuote("it's") == "'it'\\''s'")

        // 4. Injected argv serialization escapes shell separators
        let injectedArgv = ["echo", ";", "touch", "/tmp/resume-pwned"]
        let serialized = injectedArgv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
        #expect(serialized == "echo ';' touch /tmp/resume-pwned")

        // 5. TrustStore prefix matching requires word prefix or exact match, not binary alone
        let userDefaultsSuite = "test.tako.resume.security.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { defaults.removePersistentDomain(forName: userDefaultsSuite) }

        let trustStore = ResumeTrustStore(defaults: defaults)
        let cwd = "/test/repo"

        // Approving "echo hello" must NOT approve "echo ; touch /tmp/resume-pwned"
        trustStore.approve(prefix: "echo hello", cwd: cwd)
        #expect(trustStore.isApproved(argv: ["echo", "hello", "world"], cwd: cwd))
        #expect(!trustStore.isApproved(argv: ["echo", ";", "touch", "/tmp/resume-pwned"], cwd: cwd))
        #expect(!trustStore.isApproved(argv: ["echo"], cwd: cwd))
    }
}
