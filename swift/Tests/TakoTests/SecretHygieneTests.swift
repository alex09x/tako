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

    private func makeSurfaceView() -> Tako.SurfaceView {
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

    @Test func testUserDefinedRedactionPatternsForPersistedSnapshots() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }

        try redactor.addPattern("sk-ant-[0-9a-zA-Z\\-_]+")
        try redactor.addPattern("Bearer\\s+[0-9a-zA-Z\\-_]+")

        #expect(redactor.hasPatterns)
        #expect(redactor.patterns.count == 2)

        // Rejection of pathological backtracking patterns (ReDoS safety)
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("^(a+)+$")
        }
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("(a*)*")
        }
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("([0-9]+)+")
        }

        // 1. Text redaction in exported snapshot scrollback
        let originalText = "Authentication succeeded with sk-ant-api03-abcdef123456 and header Bearer eyJhbGciOiJIUzI1NiJ9. Welcome!"
        let redactedText = redactor.redact(originalText)
        #expect(redactedText == "Authentication succeeded with [REDACTED] and header [REDACTED]. Welcome!")
        #expect(!redactedText.contains("sk-ant"))
        #expect(!redactedText.contains("eyJhbGci"))

        // 2. Binary checkpoint data redaction with CRC32 update
        let payloadString = "Session log: user authenticated with sk-ant-api03-abcdef123456 token."
        let payloadBytes = [UInt8](payloadString.utf8)
        let initialCRC = SessionSnapshotRedactor.computeCRC32(data: payloadBytes)

        var checkpoint = Data("TKCK".utf8)
        var version: UInt32 = 5
        var flags: UInt32 = 0
        var payloadLen: UInt32 = UInt32(payloadBytes.count)
        var crcLE = initialCRC.littleEndian

        withUnsafeBytes(of: &version) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLen) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &crcLE) { checkpoint.append(contentsOf: $0) }
        checkpoint.append(contentsOf: payloadBytes)

        #expect(checkpoint.count == 20 + payloadBytes.count)

        // Redact binary checkpoint
        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)
        #expect(redactedCheckpoint.count == checkpoint.count)

        // Secret should not be present in redacted data
        let redactedDataString = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!redactedDataString.contains("sk-ant-api03-abcdef123456"))

        // Header checksum must match the new masked payload
        let newPayload = [UInt8](redactedCheckpoint.dropFirst(20))
        let expectedCRC = SessionSnapshotRedactor.computeCRC32(data: newPayload)
        let headerCRC = redactedCheckpoint.dropFirst(16).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(headerCRC == expectedCRC)
    }

    // MARK: - Real Terminal Checkpoint Cell Redaction & Import Test

    @Test func testRealBinaryCheckpointRedactsTerminalCellsAndRestoresSuccessfully() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }

        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")
        try redactor.addPattern("postgres://[^\\s]+")

        let core = TakoCore(cols: 80, rows: 24)
        // Feed terminal sequence so that text is placed into actual 32-bit grid cells
        core.feed(bytes: Data("Secret API: sk-live9876543210abcdef\r\nDATABASE_URL=postgres://alice:secret123@db.prod:5432/main\r\n".utf8))

        let rawBuffer = core.bufferText()
        #expect(rawBuffer.contains("sk-live9876543210abcdef"))
        #expect(rawBuffer.contains("postgres://alice:secret123@db.prod:5432/main"))

        // Export real binary checkpoint from engine
        let checkpoint = try core.checkpointExport(flags: 0, maxBytes: 0)
        #expect(checkpoint.count >= 20)
        #expect(checkpoint.prefix(4) == Data("TKCK".utf8))

        // Redact the real binary checkpoint
        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)

        // The raw secret should no longer appear anywhere in the checkpoint binary data
        let rawCheckpointString = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!rawCheckpointString.contains("sk-live9876543210abcdef"))
        #expect(!rawCheckpointString.contains("postgres://alice:secret123@db.prod:5432/main"))

        // Import the redacted checkpoint into a fresh TakoCore instance to verify structure and CRC integrity
        let restoredCore = TakoCore(cols: 80, rows: 24)
        try restoredCore.checkpointImport(blob: redactedCheckpoint)

        let restoredText = restoredCore.bufferText()
        #expect(!restoredText.contains("sk-live9876543210abcdef"))
        #expect(!restoredText.contains("postgres://alice:secret123@db.prod:5432/main"))
        #expect(restoredText.contains("Secret API: ***********************"))
        #expect(restoredText.contains("DATABASE_URL=********************************************"))
    }

    // MARK: - Finding 1: Resume Set Rejection on Secure-Input Panes

    @Test func testResumeSetRejectedOnSecureInputPanes() async throws {
        let surface = makeSurfaceView()
        defer { surface.close() }

        surface.isSecureInputMode = true
        defer { surface.isSecureInputMode = false }

        let pane = ControlCommands.Pane(surface: surface, windowID: "win-1", tabID: "tab-1", stableTabID: "tab-1")
        let all = [pane]
        let allScopes = Set(ControlScope.allCases)

        let req = ControlRequest(
            cmd: "resume",
            args: [
                "action": .string("set"),
                "target": .string(surface.id.uuidString),
                "argv": .array([.string("sh"), .string("-c"), .string("echo secret")]),
                "cwd": .string("/tmp"),
            ],
            from: nil,
            scopes: allScopes
        )

        let res = ControlCommands.handle(req, all: all)
        guard case .failure(let err) = res else {
            Issue.record("resume set must be rejected for secure-input panes")
            return
        }
        #expect(err.code == ControlError.Code.disabled)
        #expect(ResumeSessionStore.shared.record(for: surface.id) == nil)
    }

    // MARK: - Finding 2: Legacy Resume Records Sanitized on Load

    @Test func testLegacyResumeRecordsSanitizedOnLoadAndRewritten() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ResumeSessionStore(directory: tempDir)
        let paneId = UUID()

        // Create a raw legacy JSON file directly on disk containing sensitive keys
        let legacyJson: [String: Any] = [
            "argv": ["python3", "app.py"],
            "cwd": "/app",
            "env": [
                "PATH": "/usr/bin:/bin",
                "DATABASE_URL": "postgres://user:password@db.local:5432/mydb",
                "MY_PASSPHRASE": "super-secret-phrase",
                "NORMAL_VAR": "hello"
            ],
            "recordedAt": Date().timeIntervalSinceReferenceDate,
            "isImported": false
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJson)
        let fileUrl = tempDir.appendingPathComponent(paneId.uuidString).appendingPathExtension("json")
        try data.write(to: fileUrl)

        // Verify the raw file on disk currently has DATABASE_URL
        let initialDiskContent = try String(contentsOf: fileUrl, encoding: .utf8)
        #expect(initialDiskContent.contains("DATABASE_URL"))
        #expect(initialDiskContent.contains("MY_PASSPHRASE"))

        // Load record via store.record(for:)
        guard let loaded = store.record(for: paneId) else {
            Issue.record("Failed to load legacy resume record")
            return
        }

        // Environment must be sanitized in memory
        #expect(loaded.env["PATH"] == "/usr/bin:/bin")
        #expect(loaded.env["NORMAL_VAR"] == "hello")
        #expect(loaded.env["DATABASE_URL"] == nil)
        #expect(loaded.env["MY_PASSPHRASE"] == nil)

        // The file on disk must have been rewritten without the sensitive keys
        let rewrittenDiskContent = try String(contentsOf: fileUrl, encoding: .utf8)
        #expect(!rewrittenDiskContent.contains("DATABASE_URL"))
        #expect(!rewrittenDiskContent.contains("MY_PASSPHRASE"))
        #expect(rewrittenDiskContent.contains("NORMAL_VAR"))
    }

    // MARK: - Finding 3: ReDoS Safe Pattern Grammar Rejection

    @Test func testRedactionPatternRejectsAmbiguousAdjacentRepetitions() {
        // Repeated identical / overlapping quantifiers that cause catastrophic backtracking
        #expect(!SessionSnapshotRedactor.isPatternSafe("^a*a*a*a*a*a*a*b$"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("a*a*"))
        #expect(!SessionSnapshotRedactor.isPatternSafe(".*.*"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("\\w+\\w+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("([0-9]+)+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("((a+)?)+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("(a*)*"))

        // Legitimate safe patterns
        #expect(SessionSnapshotRedactor.isPatternSafe("sk-[A-Za-z0-9\\-_]+"))
        #expect(SessionSnapshotRedactor.isPatternSafe("Bearer\\s+[A-Za-z0-9\\-_]+"))
        #expect(SessionSnapshotRedactor.isPatternSafe("AKIA[0-9A-Z]{16}"))
        #expect(SessionSnapshotRedactor.isPatternSafe("ghp_[0-9a-zA-Z]{36}"))
    }

    // MARK: - Finding 4 & 5: Checkpoint Tail Redaction & Async Stale Invalidation

    @Test func testCheckpointTailAndAsyncSaveInvalidation() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("SUPER_SECRET_[0-9]+")

        // 1. Checkpoint with command input in tail
        let core = TakoCore(cols: 80, rows: 24)
        // Feed an OSC 133 command so that commands log records input line
        core.feed(bytes: Data("\u{1b}]133;A\u{07}SUPER_SECRET_987654321\u{1b}]133;B\u{07}\r\n".utf8))
        let checkpoint = try core.checkpointExport(flags: 0, maxBytes: 0)

        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)
        let redactedStr = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!redactedStr.contains("SUPER_SECRET_987654321"))

        // Must still import cleanly
        let restored = TakoCore(cols: 80, rows: 24)
        try restored.checkpointImport(blob: redactedCheckpoint)

        // 2. Async save invalidation on secure-input transition
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionSnapshotStore(directory: tempDir)
        let saver = SessionSnapshotSaver(store: store)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let surface = makeSurfaceView()
        defer { surface.close() }

        // Start save, immediately transition to secure input
        surface.core.feed(bytes: Data("Normal text\r\n".utf8))
        saver.save([surface], settings: .init(enabled: true, limit: 10_000_000, secureInput: false), asynchronous: true)

        // Enter secure input and save again
        surface.isSecureInputMode = true
        saver.save([surface], settings: .init(enabled: true, limit: 10_000_000, secureInput: false), asynchronous: true)

        // Store must not have any snapshot for the surface
        #expect(store.read(id: surface.id) == nil)
    }

    // MARK: - Finding 1: Redaction Fails Closed on Timeout

    @Test func testRedactionFailsClosedOnTimeout() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        let secret = "sk-ant-api03-abcdef123456"
        let normalText = "This is a normal line\nHere is a secret: \(secret)\nAnd another line."

        // 1. With timeout = 0.0 or negative, it must immediately fail closed without leaking the secret
        let immediateTimeout = redactor.redact(normalText, timeout: 0.0)
        #expect(!immediateTimeout.contains(secret))
        #expect(immediateTimeout.contains("[REDACTED]"))

        // 2. Negative timeout must also fail closed
        let negativeTimeout = redactor.redact(normalText, timeout: -1.0)
        #expect(!negativeTimeout.contains(secret))
        #expect(negativeTimeout.contains("[REDACTED]"))

        // 3. Normal redaction with sufficient timeout succeeds
        let normalRedacted = redactor.redact(normalText, timeout: 1.0)
        #expect(!normalRedacted.contains(secret))
        #expect(normalRedacted.contains("Here is a secret: [REDACTED]"))
        #expect(normalRedacted.contains("This is a normal line"))
    }

    // MARK: - Finding 2: Chunk Boundary Carry Window Redaction

    @Test func testRedactionOverlappingChunkBoundary() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        let secret = "sk-ant-api03-boundarysecret123"
        // Place the secret so that it straddles character offset 4096
        // Offset 4090 to 4120 in a 10,000-character line
        let prefix = String(repeating: ".", count: 4090)
        let suffix = String(repeating: ".", count: 6000)
        let longLine = prefix + secret + suffix

        #expect(longLine.count > 4096)
        let secretStart = 4090
        let secretEnd = 4090 + secret.count
        #expect(secretStart < 4096 && secretEnd > 4096) // Straddles 4096 boundary

        let redacted = redactor.redact(longLine, timeout: 2.0)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("[REDACTED]"))

        // Verify non-secret characters around the boundary are intact
        #expect(redacted.hasPrefix(prefix))
        #expect(redacted.hasSuffix(suffix))
        #expect(redacted == prefix + "[REDACTED]" + suffix)

        // Also test multiple secrets straddling consecutive chunk boundaries
        let secondSecret = "sk-ant-api03-secondsecret456"
        // Place second secret at offset 8180 (straddling next boundary)
        let middle = String(repeating: ".", count: 8180 - secretEnd)
        let multiChunkLine = prefix + secret + middle + secondSecret + suffix
        let multiRedacted = redactor.redact(multiChunkLine, timeout: 2.0)
        #expect(!multiRedacted.contains(secret))
        #expect(!multiRedacted.contains(secondSecret))
        #expect(multiRedacted == prefix + "[REDACTED]" + middle + "[REDACTED]" + suffix)
    }

    // MARK: - Finding 3: Unbounded Match Span Does Not Leak Tail

    @Test func testRedactionUnboundedMatchSpanDoesNotLeakTail() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        // 1. Secret span longer than initial window (6144), e.g. 8000 characters:
        // Window expands to establish match completion and redacts the full token without leaking the tail.
        let tokenBody = String(repeating: "x", count: 8000)
        let longSecret = "sk-" + tokenBody
        let prefix = String(repeating: ".", count: 2000)
        let suffix = String(repeating: ".", count: 2000)
        let line = prefix + longSecret + suffix

        let redacted = redactor.redact(line, timeout: 2.0)
        #expect(!redacted.contains("sk-"))
        #expect(!redacted.contains(String(repeating: "x", count: 50)))
        #expect(redacted.contains("[REDACTED]"))
        #expect(redacted == prefix + "[REDACTED]" + suffix)

        // 2. Secret span that exceeds maximum expanded window (32768):
        // Fails closed by replacing with [REDACTED], ensuring the tail is never leaked.
        let hugeBody = String(repeating: "y", count: 40000)
        let hugeSecret = "sk-" + hugeBody
        let hugeLine = prefix + hugeSecret + suffix

        let hugeRedacted = redactor.redact(hugeLine, timeout: 2.0)
        #expect(!hugeRedacted.contains("sk-"))
        #expect(!hugeRedacted.contains(String(repeating: "y", count: 50)))
        #expect(hugeRedacted.contains("[REDACTED]"))
    }
}

