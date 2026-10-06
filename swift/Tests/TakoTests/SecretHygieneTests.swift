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
import Foundation
import Testing
@testable import Tako

@Suite(.serialized) @MainActor struct SecretHygieneTests {

    func makeSurfaceView() -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.selfTestCapturing = true
        return view
    }

    // MARK: - Definition of Done: Password typed under secure input is found in NONE of the 7 places

    @Test func testSecureInputSessionExcludedFromAllPlaces() async throws {
        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let oldGlobal = SecureInput.shared.global
        SecureInput.shared.global = false
        defer { SecureInput.shared.global = oldGlobal }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotStore = SessionSnapshotStore(directory: tempDir.appendingPathComponent("Snapshots"))

        let surface = makeSurfaceView()
        defer { surface.close() }

        let pane = ControlCommands.Pane(surface: surface, windowID: "win-1", tabID: "tab-1", stableTabID: "tab-1")
        let all = [pane]

        let secret = "SuperSecretPassword123!"

        // 1. Feed the secret text into the terminal engine
        surface.core.feed(bytes: Data("Enter password: \(secret)\r\n".utf8))

        // 2. Enable secure input on this surface
        surface.isSecureInputMode = true
        defer { surface.isSecureInputMode = false }
        #expect(surface.isSecureInput)
        #expect(SecureInput.shared.isSecure(for: surface))

        // ==========================================
        // Place 1: Snapshots
        // ==========================================
        // a) Periodic snapshot saver must skip secure-input surfaces
        let saver = SessionSnapshotSaver(store: snapshotStore)
        saver.save([surface], settings: .init(enabled: true, limit: 10_000_000, secureInput: false))
        #expect(snapshotStore.read(id: surface.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: snapshotStore.url(for: surface.id).path))

        // b) Session export must omit scrollback and resume records for secure-input panes
        let exportUrl = tempDir.appendingPathComponent("exported_session.json")
        let exportFile = try SessionExportManager.shared.exportPanes([surface], to: exportUrl)
        let exportedPane = exportFile.windows.first?.panes.first(where: { $0.id == surface.id })
        #expect(exportedPane != nil)
        #expect(exportedPane?.scrollback == "")
        #expect(exportedPane?.resume == nil)

        let exportJson = try String(contentsOf: exportUrl, encoding: .utf8)
        #expect(!exportJson.contains(secret))

        // ==========================================
        // Place 2: Search
        // ==========================================
        // a) Cross-session search open terminals must exclude the secure-input pane
        let targets = CrossSessionSearch.openTerminals()
        #expect(!targets.contains(where: { $0.surfaceID == surface.id }))

        // b) In-pane search bar must refuse to start on secure surface
        surface.startSearch(needle: secret)
        #expect(surface.searchState == nil)

        // c) Control command `find` must not find the secret
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ControlCommands.find(secret, limit: 10) { res in
                guard case .ok(let dict) = res, let matches = dict["matches"]?.array else {
                    Issue.record("find failed: \(res)")
                    continuation.resume()
                    return
                }
                #expect(matches.isEmpty)
                continuation.resume()
            }
        }

        // ==========================================
        // Place 3: History
        // ==========================================
        // Ending a command while in secure input mode must never be recorded
        CommandHistoryStore.shared.record(
            command: "login --password \(secret)",
            cwd: "/tmp",
            startedAt: Date(),
            duration: 0.1,
            exitCode: 0,
            paneId: surface.id,
            isSecure: true
        )
        #expect(CommandHistoryStore.shared.search(query: secret).isEmpty)
        #expect(CommandHistoryStore.shared.allEntries().filter { $0.command.contains(secret) }.isEmpty)

        let allScopes = Set(ControlScope.allCases)

        let histReq = ControlRequest(cmd: "history", args: ["query": .string(secret)], from: nil, scopes: allScopes)
        let histRes = ControlCommands.handle(histReq, all: all)
        guard case .ok(let histDict) = histRes, let entries = histDict["entries"]?.array else {
            Issue.record("history command failed: \(histRes)")
            return
        }
        #expect(entries.isEmpty)

        // ==========================================
        // Place 4: takoctl text
        // ==========================================
        let textReq = ControlRequest(cmd: "text", args: ["target": .string(surface.id.uuidString)], from: nil, scopes: allScopes)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ControlCommands.handle(textReq, all: all) { res in
                guard case .failure(let err) = res else {
                    Issue.record("text command should be disabled for secure-input pane")
                    continuation.resume()
                    return
                }
                #expect(err.code == ControlError.Code.disabled)
                #expect(err.message.contains("secure-input panes cannot be read"))
                continuation.resume()
            }
        }

        // ==========================================
        // Place 5: last (takoctl last)
        // ==========================================
        let lastReq = ControlRequest(cmd: "last", args: ["target": .string(surface.id.uuidString)], from: nil, scopes: allScopes)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ControlCommands.handle(lastReq, all: all) { res in
                guard case .failure(let err) = res else {
                    Issue.record("last command should be disabled for secure-input pane")
                    continuation.resume()
                    return
                }
                #expect(err.code == ControlError.Code.disabled)
                #expect(err.message.contains("secure-input panes cannot be read"))
                continuation.resume()
            }
        }

        // ==========================================
        // Place 6: Screenshots
        // ==========================================
        let screenshotReq = ControlRequest(cmd: "screenshot", args: ["target": .string(surface.id.uuidString)], from: nil, scopes: allScopes)
        let screenshotRes = ControlCommands.handle(screenshotReq, all: all)
        guard case .failure(let errScreenshot) = screenshotRes else {
            Issue.record("screenshot command should be disabled for secure-input pane")
            return
        }
        #expect(errScreenshot.code == ControlError.Code.disabled)
        #expect(errScreenshot.message.contains("secure-input panes cannot be read"))

        // ==========================================
        // Place 7: Companion app
        // ==========================================
        #expect(!CompanionAccessGate.isAccessAllowed(for: surface))
        #expect(throws: ControlError.self) {
            try CompanionAccessGate.checkAccess(for: surface)
        }

        let companionReq = ControlRequest(
            cmd: "send",
            args: ["target": .string(surface.id.uuidString), "text": .string("hello")],
            from: nil,
            client: "companion-device",
            scopes: allScopes
        )
        let companionRes = ControlCommands.handle(companionReq, all: all)
        guard case .failure(let errCompanion) = companionRes else {
            Issue.record("companion access should be rejected for secure-input pane")
            return
        }
        #expect(errCompanion.code == ControlError.Code.disabled)
        #expect(errCompanion.message.contains("companion"))
    }

    // MARK: - Secret Environment Variable Dropping

    @Test func testResumeBindingsAndExportsDropSecretEnvironmentVariables() {
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/alex",
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "USER": "alex",
            "OPENAI_API_KEY": "sk-secret123",
            "GITHUB_TOKEN": "ghp_secret456",
            "DB_PASSWORD": "mypassword",
            "SECRET_SALT": "xyz",
            "AUTH_BEARER": "bearer-token",
            "AWS_CREDENTIAL_FILE": "/path/to/creds",
            "PRIVATE_SIGNING_KEY": "pem-content",
            "ACCESS_ID": "id-999",
            "SOME_PASSWD": "12345",
            "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
            "SSL_CERT_FILE": "/etc/ssl/cert.pem",
            "APIKEY": "key-val",
            "MY_PASSPHRASE": "phrase",
            "DB_PASS": "pass1",
            "DB_PWD": "pwd1",
            "DATABASE_URL": "postgres://user:password@host/db",
            "REDIS_URL": "redis://:secret@cache:6379/0",
            "MONGO_URI": "mongodb://root:pass@mongo.db:27017",
            "POSTGRES_URL": "postgresql://user:pass@localhost/db",
            "AMQP_URL": "amqp://user:pass@localhost:5672",
            "SENTRY_DSN": "https://public:private@sentry.io/1",
            "CUSTOM_CRED_URL": "https://api-user:secret123@api.internal.com",
            "SAFE_CONFIG_URL": "https://api.github.com/repos",
        ]

        // 1. ResumeSessionStore.sanitizeEnvironment drops all secret keys and credential URLs
        let sanitized = ResumeSessionStore.sanitizeEnvironment(env)
        #expect(sanitized["PATH"] == "/usr/bin:/bin")
        #expect(sanitized["HOME"] == "/Users/alex")
        #expect(sanitized["TERM"] == "xterm-256color")
        #expect(sanitized["SHELL"] == "/bin/zsh")
        #expect(sanitized["LANG"] == "en_US.UTF-8")
        #expect(sanitized["USER"] == "alex")
        #expect(sanitized["SAFE_CONFIG_URL"] == "https://api.github.com/repos")

        #expect(sanitized["OPENAI_API_KEY"] == nil)
        #expect(sanitized["GITHUB_TOKEN"] == nil)
        #expect(sanitized["DB_PASSWORD"] == nil)
        #expect(sanitized["SECRET_SALT"] == nil)
        #expect(sanitized["AUTH_BEARER"] == nil)
        #expect(sanitized["AWS_CREDENTIAL_FILE"] == nil)
        #expect(sanitized["PRIVATE_SIGNING_KEY"] == nil)
        #expect(sanitized["ACCESS_ID"] == nil)
        #expect(sanitized["SOME_PASSWD"] == nil)
        #expect(sanitized["SSH_AUTH_SOCK"] == nil)
        #expect(sanitized["SSL_CERT_FILE"] == nil)
        #expect(sanitized["APIKEY"] == nil)
        #expect(sanitized["MY_PASSPHRASE"] == nil)
        #expect(sanitized["DB_PASS"] == nil)
        #expect(sanitized["DB_PWD"] == nil)
        #expect(sanitized["DATABASE_URL"] == nil)
        #expect(sanitized["REDIS_URL"] == nil)
        #expect(sanitized["MONGO_URI"] == nil)
        #expect(sanitized["POSTGRES_URL"] == nil)
        #expect(sanitized["AMQP_URL"] == nil)
        #expect(sanitized["SENTRY_DSN"] == nil)
        #expect(sanitized["CUSTOM_CRED_URL"] == nil)

        // 2. ExportedResume automatically sanitizes environment
        let exported = ExportedResume(argv: ["zsh"], cwd: "/tmp", env: env)
        #expect(exported.env?["PATH"] == "/usr/bin:/bin")
        #expect(exported.env?["OPENAI_API_KEY"] == nil)
        #expect(exported.env?["DATABASE_URL"] == nil)
        #expect(exported.env?["CUSTOM_CRED_URL"] == nil)
        #expect(exported.env?["SSH_AUTH_SOCK"] == nil)
        #expect(exported.env?["SSL_CERT_FILE"] == nil)
        #expect(exported.env?["SAFE_CONFIG_URL"] == "https://api.github.com/repos")

        // 3. ResumeSessionStore rejects saving records when isSecure is true
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ResumeSessionStore(directory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paneId = UUID()
        let record = ResumeSessionRecord(argv: ["sh"], cwd: "/tmp", env: env)
        store.set(record: record, for: paneId, isSecure: true)
        #expect(store.record(for: paneId) == nil)
    }

    // MARK: - User-Defined Redaction Patterns for Persisted Snapshots

}
