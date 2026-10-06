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
import SwiftUI

// A terminal session on the phone.
//
// iOS forbids fork/exec, so a session here is always remote -- the design's
// list is ssh hosts, not local shells. The transport is the engine's own SSH
// client, which means the bytes never leave Rust between the socket and the
// grid.

@MainActor
final class Session: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    let kind: Kind
    @Published var title: String
    @Published var subtitle: String
    @Published var status: Status
    @Published private(set) var crab: CrabState = .idle
    /// The current server-owned keyboard-interactive round, if any. Answers
    /// intentionally live only in the presented sheet, never on Session.
    @Published var authenticationChallenge: SSHAuthenticationChallenge?

    let core: TakoCore

    nonisolated static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(kind: Kind, title: String, subtitle: String, status: Status) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.core = TakoCore(cols: 80, rows: 24)
    }

    /// The live connection, once there is one.
    private var ssh: SshSession?

    /// The local demo has no process or PTY behind it: iOS cannot fork a
    /// shell. It still needs the other half of a terminal, though. Keep a
    /// small editable command line and execute a deterministic set of demo
    /// commands so Return behaves exactly like Return instead of merely
    /// moving the renderer's cursor back to column zero.
    var demoLine = Data()
    var demoEscapeState = 0
    var demoLastByteWasCarriageReturn = false

    /// The view currently showing this session, so a resize can be pushed at
    /// the remote when one appears. A session outlives its surface.
    weak var surface: TakoTerminalView?

    /// True when this is a saved host with nothing to authenticate with:
    /// the app deliberately does not keep keys or passwords, so a card
    /// restored from the last launch has to go through the form again rather
    /// than fail at the far end with something unhelpful.
    var needsCredentials: Bool {
        guard case .ssh(let target) = kind else { return false }
        let key = target.privateKeyPEM ?? ""
        let password = target.password ?? ""
        return key.isEmpty && password.isEmpty
    }

    /// Enough to fill the form in again.
    var draft: SshDraft? {
        guard case .ssh(let target) = kind else { return nil }
        var draft = SshDraft()
        draft.host = target.host
        draft.port = String(target.port)
        draft.username = target.username
        return draft
    }

    /// The state behind the key row. On the session rather than the view so
    /// an armed ⌃ survives the view being rebuilt, and so a scripted run can
    /// press the same keys through the same code.
    let keyRow = KeyRow()

    /// The surface went away (navigated back). The connection stays: a
    /// phone backgrounds a view constantly and dropping the shell each time
    /// would make the app unusable.
    func surfaceWentAway() {
        surface = nil
    }

    /// User input routing: the demo session loops back in-process, an ssh
    /// session goes out over the wire.
    func sendInput(_ data: Data) {
        switch kind {
        case .local:
            handleDemoInput(data)
        case .ssh:
            ssh?.send(data: data)
        }
    }

    /// Device replies (DSR, CPR, and the rest) are answers to the program on
    /// the far end, so they travel the same path as typing.
    func sendDeviceReply(_ data: Data) {
        sendInput(data)
    }

    /// Resize handling. The grid resizes either way; a remote also has to be
    /// told, or it keeps drawing to the old width.
    func handleResize(cols: Int, rows: Int) {
        core.resize(cols: UInt32(cols), rows: UInt32(rows))
        ssh?.resize(cols: UInt32(cols), rows: UInt32(rows))
    }

    /// Opens the connection. Safe to call twice; the second call is ignored
    /// while the first is still live.
    func connect() {
        guard case .ssh(let target) = kind, ssh == nil else { return }
        status = .connecting

        let auth: SshAuth
        if let pem = target.privateKeyPEM {
            auth = .privateKey(pem: pem, passphrase: target.passphrase)
        } else {
            auth = .password(password: target.password ?? "")
        }

        ssh = SshSession.connect(
            config: SshConfig(
                host: target.host,
                port: target.port,
                username: target.username,
                auth: auth,
                term: "xterm-256color",
                cols: core.cols(),
                rows: core.rows()
            ),
            events: SessionEvents(
                session: self,
                host: target.host,
                trusted: KnownHosts.fingerprint(for: target.host, port: target.port)
            )
        )
    }

    /// Closes the connection and lets the session be reconnected.
    func disconnect() {
        authenticationChallenge = nil
        ssh?.disconnect()
        ssh = nil
    }

    /// Sends exactly the answers belonging to the challenge currently on
    /// screen. Clearing first also makes a rapid second tap a harmless no-op.
    func submitAuthenticationChallenge(_ responses: [String]) {
        guard let challenge = authenticationChallenge else { return }
        authenticationChallenge = nil
        ssh?.answerKeyboardInteractive(
            challengeId: challenge.id,
            responses: responses
        )
    }

    /// Dismissing an MFA prompt without answering is a protocol decision:
    /// tell Rust to end the authentication instead of leaving it stalled.
    func cancelAuthenticationChallenge() {
        guard let challenge = authenticationChallenge else { return }
        authenticationChallenge = nil
        ssh?.cancelKeyboardInteractive(challengeId: challenge.id)
    }

    /// A text field in the MFA sheet takes first responder from the terminal.
    /// Presenting the sheet does not remove the terminal from its window, so
    /// `didMoveToWindow` cannot restore the keyboard when the sheet leaves.
    /// Do it explicitly after SwiftUI's dismissal has completed.
    func restoreTerminalFocusAfterAuthentication() {
        guard authenticationChallenge == nil,
              let surface,
              surface.window != nil,
              !surface.isFirstResponder else { return }
        _ = surface.becomeFirstResponder()
    }

    // MARK: - Called from the transport thread

    /// Not fileprivate: unit tests drive status transitions directly, since
    /// they have no real transport to close or connect behind them.
    func transportConnected() {
        // A legal zero-prompt informational round is answered by Rust and
        // may briefly reach the UI immediately before this callback.
        authenticationChallenge = nil
        status = .connected
    }

    func transportClosed(_ reason: String) {
        authenticationChallenge = nil
        ssh = nil
        status = .disconnected(since: reason.isEmpty ? "closed" : reason)
        crab = reason.isEmpty ? .idle : .failed
    }

    func transportAuthenticationChallenge(
        challengeId: UInt64,
        name: String,
        instructions: String,
        prompts: [SshPrompt]
    ) {
        // Do not leave the terminal accepting keystrokes behind the modal.
        // In particular, iOS may put its Save Password alert above this sheet;
        // attempting to focus a prompt underneath that system window is a
        // timing race and can leave either responder active afterwards.
        surface?.resignFirstResponder()
        authenticationChallenge = SSHAuthenticationChallenge(
            id: challengeId,
            name: name,
            instructions: instructions,
            prompts: prompts.enumerated().map { index, prompt in
                .init(id: index, text: prompt.prompt, echo: prompt.echo)
            }
        )
    }

    /// Bell handling.
    func handleBell() {
        crab = .attention
    }

    func commandDidStart() {
        crab = .running
    }

    func commandDidEnd(exitCode: Int32?) {
        crab = (exitCode ?? 0) == 0 ? .succeeded : .failed
    }

    /// When the far end last sent anything. Scripted input waits for this
    /// to go quiet, i.e. for the shell to have finished drawing its prompt.
    private(set) var lastReceivedAt: Date?

    /// Bytes arriving from the far end.
    func receive(_ data: Data) {
        lastReceivedAt = Date()
        // A mounted surface owns parsing, host events and redraw scheduling.
        // Feeding the shared core behind its back changes the grid but never
        // wakes its display link, so output can stop visibly mid-command
        // after the app resumes from background.
        if let surface {
            surface.enqueue(data: data)
            return
        }

        // Keep sessions current while their screen is not mounted. There is
        // nothing to draw, but terminal replies still belong on the wire and
        // command/title/bell state still belongs on the session card.
        core.feed(bytes: data)
        let reply = core.takeOutput()
        if !reply.isEmpty {
            ssh?.send(data: reply)
        }
        for event in core.takeEvents() {
            switch event {
            case .commandStart: commandDidStart()
            case .commandEnd(let code): commandDidEnd(exitCode: code)
            case .titleChanged(let t): title = t
            case .bell: crab = .attention
            default: break
            }
        }
    }
}
