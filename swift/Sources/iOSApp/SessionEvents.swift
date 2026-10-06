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

/// The transport's callbacks arrive on its own thread; the session is
/// `@MainActor`, so everything hops before it touches published state.
///
/// The host-key answer is the exception: it is a decision the transport is
/// waiting on before it sends a password, so it is answered synchronously
/// against state that only the main actor writes.
final class SessionEvents: SshEvents, @unchecked Sendable {
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
