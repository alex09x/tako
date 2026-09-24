//  Public result and error types for an ordered checkpoint restore.
//
//  They live here rather than beside either view: both the UIKit
//  `TakoTerminalView` and the AppKit `TakoTerminalNSView` hand them back, and
//  the coordinator that produces them belongs to neither.

import Foundation

/// What a restored checkpoint turned out to be.
///
/// The dimensions are the *restored* terminal's own. They are reported, not
/// adopted as a resize: a mirror consumer does not own PTY geometry, so a grid
/// that comes back 132x43 into a view laid out for 80x24 is not reflowed here.
/// The host decides whether its layout is genuinely newer and, if it is,
/// issues that intent through its own ordered path.
public struct TerminalCheckpointRestore: Sendable, Equatable {
    public let version: UInt32
    public let cols: Int
    public let rows: Int
    public let payloadLength: Int
    /// The engine generation published by the swap. Anything captured under an
    /// earlier one no longer describes this terminal.
    public let epoch: UInt64
}

/// Why an ordered checkpoint import did not happen.
///
/// The engine's own refusals (`TakoCheckpointError`) are rethrown unchanged --
/// the point of the typed core API is that a caller can tell an unsupported
/// version from a corrupt payload, and wrapping them would throw that away.
public enum TerminalCheckpointImportError: Error, Equatable {
    /// The coordinator was torn down before the barrier reached the engine.
    case shutDown
}

/// The engine's refusal, classified for a caller outside this module.
///
/// UniFFI generates `TakoCheckpointError` without `public`, so a host that
/// merely imports `TakoCoreUI` can catch what the checkpoint calls throw but
/// cannot match on it -- which is exactly the distinction the typed API was
/// added to provide. Nothing here changes what is thrown: the engine's error
/// still travels unchanged, and in-module code still matches it directly.
/// This is the reading of it that survives the module boundary.
public enum TerminalCheckpointFailure: Error, Equatable, Sendable {
    /// A container this build cannot read. Negotiate down, do not retry.
    case unsupportedVersion(version: UInt32)
    /// The payload is damaged. Retrying the same bytes will not help.
    case corrupt(reason: String)
    /// Refused against a cap -- the caller's `maxBytes`, or the wire limit.
    case tooLarge(size: UInt64, limit: UInt64)
    /// The engine was handed no blob at all.
    case nullArgument
    /// The coordinator was torn down before the barrier reached the engine.
    case shutDown
    /// Something this classification does not know about, kept rather than
    /// flattened so a caller can still log the truth.
    case other(description: String)

    /// Classify anything thrown by a checkpoint call.
    public init(_ error: Error) {
        switch error {
        case TakoCheckpointError.UnsupportedVersion(let version):
            self = .unsupportedVersion(version: version)
        case TakoCheckpointError.Corrupt(let reason):
            self = .corrupt(reason: reason)
        case TakoCheckpointError.TooLarge(let size, let limit):
            self = .tooLarge(size: size, limit: limit)
        case TakoCheckpointError.NullArgument:
            self = .nullArgument
        case TerminalCheckpointImportError.shutDown:
            self = .shutDown
        default:
            self = .other(description: String(reflecting: error))
        }
    }

    /// Whether a differently-versioned peer could still succeed. A damaged
    /// payload cannot; an unreadable version can, once negotiated.
    public var isRecoverableByNegotiation: Bool {
        if case .unsupportedVersion = self { return true }
        return false
    }
}
