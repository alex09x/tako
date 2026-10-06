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

extension Session {
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
