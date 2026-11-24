/*
 * tako — Terminal permission models and kinds
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AVFoundation
import Foundation

/// The category of system permission relevant to terminal emulator operations.
public enum TerminalPermissionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case protectedFolders
    case fullDiskAccess
    case localNetwork
    case microphone
    case screenCapture
    case systemAudio
    case automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .protectedFolders: "Protected Folders"
        case .fullDiskAccess: "Full Disk Access"
        case .localNetwork: "Local Network"
        case .microphone: "Microphone"
        case .screenCapture: "Screen Recording"
        case .systemAudio: "System Audio"
        case .automation: "Automation"
        }
    }

    public var explanation: String {
        switch self {
        case .protectedFolders:
            "Use Desktop, Documents and Downloads."
        case .fullDiskAccess:
            "Optional access beyond your standard folders."
        case .localNetwork:
            "Connect to nearby SSH hosts and services."
        case .microphone:
            "Audio input for a voice or recording tool."
        case .screenCapture:
            "Capture other apps and displays."
        case .systemAudio:
            "Record audio played by other apps."
        case .automation:
            "Let a script control a specific app."
        }
    }

    /// Whether this permission can be prompted directly via public Apple APIs.
    public var canRequestDirectly: Bool {
        switch self {
        case .microphone, .screenCapture, .localNetwork:
            return true
        default:
            return false
        }
    }

    /// Associated AVFoundation media type if applicable.
    public var mediaType: AVMediaType? {
        switch self {
        case .microphone:
            return .audio
        default:
            return nil
        }
    }

    /// The System Settings URL query or path for managing this permission.
    public var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenCapture:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .fullDiskAccess:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .protectedFolders:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        case .localNetwork:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .systemAudio:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }
    }

}

/// The observed access status of a permission.
public enum TerminalPermissionStatus: String, CaseIterable, Hashable, Sendable {
    case allowed
    case denied
    case notAsked
    case restricted
    case notAllowed
    case managedInSettings
    case unknown

    public var title: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .notAsked: "Not Requested"
        case .restricted: "Restricted"
        case .notAllowed: "Not Allowed"
        case .managedInSettings: "Managed in Settings"
        case .unknown: "Unknown"
        }
    }

    public var isAllowed: Bool {
        self == .allowed
    }
}

/// Represents the permission state of a single capability.
public struct TerminalPermission: Identifiable, Hashable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: TerminalPermissionKind
    public let title: String
    public let explanation: String
    public let status: TerminalPermissionStatus

    public var isAllowed: Bool { status.isAllowed }
    public var canRequest: Bool { kind.canRequestDirectly }

    public init(
        kind: TerminalPermissionKind,
        status: TerminalPermissionStatus,
        title: String? = nil,
        explanation: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.title = title ?? kind.title
        self.explanation = explanation ?? kind.explanation
    }
}

/// The compact result returned after requesting a permission.
public struct TerminalPermissionRequestResult: Hashable, Equatable, Sendable {
    public let kind: TerminalPermissionKind
    public let status: TerminalPermissionStatus
    public let message: String
    public let isAllowed: Bool
    public let didPrompt: Bool

    public var isRefused: Bool { !didPrompt }

    public init(
        kind: TerminalPermissionKind,
        status: TerminalPermissionStatus,
        message: String,
        didPrompt: Bool = true
    ) {
        self.kind = kind
        self.status = status
        self.message = message
        self.isAllowed = (status == .allowed)
        self.didPrompt = didPrompt
    }
}
