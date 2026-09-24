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
    enum Kind: Equatable {
        case local          // the demo session, driven in-process
        case ssh(SshTarget)
    }

    /// Where an ssh session goes and how it proves who it is.
    struct SshTarget: Equatable {
        var host: String
        var port: UInt16 = 22
        var username: String
        /// A private key in its armoured text form, or a password. Keys are
        /// preferred: a password typed on a phone keyboard, over a
        /// connection whose host key nobody checked, is two bad ideas.
        var privateKeyPEM: String?
        var passphrase: String?
        var password: String?
    }

    enum Status: Equatable {
        case connected
        case connecting
        case disconnected(since: String)

        var label: String {
            switch self {
            case .connected: return "connected"
            case .connecting: return "connecting"
            case .disconnected(let since): return "disconnected · \(since)"
            }
        }
    }

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
    private var demoLine = Data()
    private var demoEscapeState = 0
    private var demoLastByteWasCarriageReturn = false

    private static let demoPrompt =
        "\u{1b}[1;38;2;244;88;28m❯\u{1b}[0m "

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

    /// Seed the demo session with something to look at.
    func seedDemo() {
        demoLine.removeAll(keepingCapacity: true)
        demoEscapeState = 0
        demoLastByteWasCarriageReturn = false
        let banner = """
        \u{1b}[1;38;2;244;88;28m❯\u{1b}[0m tail -f api.log\r
        \u{1b}[38;2;138;127;118m12:41:02\u{1b}[0m GET  /health    \u{1b}[38;2;123;216;143m200\u{1b}[0m   3ms\r
        \u{1b}[38;2;138;127;118m12:41:09\u{1b}[0m POST /v1/sync   \u{1b}[38;2;123;216;143m200\u{1b}[0m  41ms\r
        \u{1b}[38;2;138;127;118m12:41:11\u{1b}[0m GET  /v1/user   \u{1b}[38;2;240;198;116m304\u{1b}[0m   2ms\r
        \u{1b}[38;2;138;127;118m12:41:15\u{1b}[0m POST /v1/push   \u{1b}[38;2;213;78;83m500\u{1b}[0m  88ms\r
        \u{1b}[38;2;138;127;118minteractive demo · type help\u{1b}[0m\r
        \u{1b}[1;38;2;244;88;28m❯\u{1b}[0m 
        """
        receive(Data(banner.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    /// A terminal emulator consumes output; it does not interpret a command
    /// line. SSH supplies a real shell on the far end, while the in-process
    /// demo supplies this deliberately small peer. It provides canonical
    /// input echo, Return, Backspace and Ctrl+C semantics without pretending
    /// that iOS can run arbitrary local programs.
    private func handleDemoInput(_ data: Data) {
        for byte in data {
            if consumeDemoEscapeByte(byte) {
                demoLastByteWasCarriageReturn = false
                continue
            }

            switch byte {
            case 0x0D: // Return from the software or hardware keyboard.
                finishDemoLine()
                demoLastByteWasCarriageReturn = true

            case 0x0A: // Accept pasted LF, but do not run CRLF twice.
                if !demoLastByteWasCarriageReturn {
                    finishDemoLine()
                }
                demoLastByteWasCarriageReturn = false

            case 0x08, 0x7F: // Backspace / DEL.
                eraseDemoCharacter()
                demoLastByteWasCarriageReturn = false

            case 0x03: // Ctrl+C: cancel the current line and show a prompt.
                demoLine.removeAll(keepingCapacity: true)
                receive(Data("^C\r\n\(Self.demoPrompt)".utf8))
                demoLastByteWasCarriageReturn = false

            case 0x0C: // Ctrl+L: clear while preserving the current line.
                let line = String(data: demoLine, encoding: .utf8) ?? ""
                receive(Data("\u{1b}[2J\u{1b}[H\(Self.demoPrompt)\(line)".utf8))
                demoLastByteWasCarriageReturn = false

            case 0x09: // A visible, editable tab in lieu of shell completion.
                let spaces = Data("    ".utf8)
                demoLine.append(spaces)
                receive(spaces)
                demoLastByteWasCarriageReturn = false

            case 0x20...0xFF:
                demoLine.append(byte)
                receive(Data([byte]))
                demoLastByteWasCarriageReturn = false

            default:
                // Other control bytes have no useful demo-side meaning.
                demoLastByteWasCarriageReturn = false
            }
        }
    }

    /// Consume a terminal escape sequence sent by the extra key row. Arrow
    /// keys do not edit this tiny line discipline yet, but they must not leak
    /// their CSI bytes into the next command either.
    private func consumeDemoEscapeByte(_ byte: UInt8) -> Bool {
        switch demoEscapeState {
        case 0:
            if byte == 0x1B {
                demoEscapeState = 1
                return true
            }
            return false
        case 1:
            if byte == 0x5B || byte == 0x4F { // CSI or SS3.
                demoEscapeState = 2
                return true
            }
            demoEscapeState = 0
            return true
        default:
            if (0x40...0x7E).contains(byte) {
                demoEscapeState = 0
            }
            return true
        }
    }

    private func eraseDemoCharacter() {
        guard !demoLine.isEmpty else { return }
        if let line = String(data: demoLine, encoding: .utf8), !line.isEmpty {
            demoLine = Data(line.dropLast().utf8)
        } else {
            // Keep malformed/incomplete input recoverable one byte at a time.
            demoLine.removeLast()
        }
        receive(Data("\u{08} \u{08}".utf8))
    }

    private func finishDemoLine() {
        let line = String(data: demoLine, encoding: .utf8) ?? ""
        demoLine.removeAll(keepingCapacity: true)
        receive(Data("\r\n".utf8))

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
        let arguments = trimmed.dropFirst(command.count).trimmingCharacters(in: .whitespaces)

        switch command {
        case "":
            break
        case "ls":
            receive(Data("README.md  \u{1b}[38;2;123;216;143mSources/\u{1b}[0m  Tests/  examples/\r\n".utf8))
        case "pwd":
            receive(Data("/demo\r\n".utf8))
        case "echo":
            receive(Data("\(arguments)\r\n".utf8))
        case "help":
            receive(Data("demo commands: ls, pwd, echo, clear, help\r\n".utf8))
        case "clear":
            receive(Data("\u{1b}[2J\u{1b}[H".utf8))
        default:
            receive(Data("tako-demo: command not found: \(command)\r\n".utf8))
        }

        receive(Data(Self.demoPrompt.utf8))
    }
}

/// The crab, on the phone. Same states as the Mac, drawn as a dot in the
/// session list and beside the title in a session.
enum CrabState: Equatable {
    case idle, running, succeeded, failed, attention, ghost

    var color: Color {
        switch self {
        case .succeeded: return Brand.ok
        case .failed: return Brand.error
        case .ghost: return Brand.dim
        case .running, .attention: return Brand.ember
        case .idle: return Brand.dim
        }
    }
}

extension Session {
    /// The dot on the card: green when the session is live, orange while it
    /// is reconnecting, grey when it is not there.
    var statusColor: Color {
        switch status {
        case .connected: return Brand.ok
        case .connecting: return Brand.claw
        case .disconnected: return Brand.dim
        }
    }
}

enum Brand {
    static let ember = Color(red: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255)
    static let claw = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x3D / 255)
    static let ink = Color(red: 0x1A / 255, green: 0x15 / 255, blue: 0x12 / 255)
    static let paper = Color(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255)
    static let dim = Color(red: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255)
    static let text = Color(red: 0xED / 255, green: 0xE6 / 255, blue: 0xDF / 255)
    static let ok = Color(red: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255)
    static let error = Color(red: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255)
    /// The terminal body: warm and nearly black, per the design.
    static let surface = Color(red: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255)
    static let card = Color(red: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255)
    static let hairline = Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255)
    static let key = Color(red: 0x2E / 255, green: 0x25 / 255, blue: 0x1E / 255)
    static let keyAccent = Color(red: 0x3A / 255, green: 0x2A / 255, blue: 0x1E / 255)
    static let rust = Color(red: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255)
}

/// The transport's callbacks arrive on its own thread; the session is
/// `@MainActor`, so everything hops before it touches published state.
///
/// The host-key answer is the exception: it is a decision the transport is
/// waiting on before it sends a password, so it is answered synchronously
/// against state that only the main actor writes.
private final class SessionEvents: SshEvents, @unchecked Sendable {
    private weak var session: Session?
    private let host: String
    /// The fingerprint trusted for this host, read on the main actor before
    /// the connection started. The transport asks about the host key from its
    /// own thread, and reaching back for main-actor state from there traps --
    /// it is not a race that goes unnoticed, it is an immediate crash.
    private let trusted: String?

    init(session: Session, host: String, trusted: String?) {
        self.session = session
        self.host = host
        self.trusted = trusted
    }

    func onHostKey(algorithm: String, fingerprint: String) -> Bool {
        // By the time a real connection goes out the host has been seen and
        // accepted through `KnownHosts.probe`. All this does is hold the
        // line: a key that no longer matches is refused outright.
        trusted == fingerprint
    }

    func onConnected() {
        Task { @MainActor in session?.transportConnected() }
    }

    func onKeyboardInteractive(
        challengeId: UInt64,
        name: String,
        instructions: String,
        prompts: [SshPrompt]
    ) {
        // Never block UniFFI's callback thread while a person is typing.
        Task { @MainActor in
            session?.transportAuthenticationChallenge(
                challengeId: challengeId,
                name: name,
                instructions: instructions,
                prompts: prompts
            )
        }
    }

    func onData(data: Data) {
        Task { @MainActor in session?.receive(data) }
    }

    func onClosed(reason: String) {
        Task { @MainActor in session?.transportClosed(reason) }
    }
}
