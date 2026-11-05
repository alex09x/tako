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
            "macOS asks when a program opens Desktop, Documents or Downloads. Review the access for the app or program named in the request."
        case .fullDiskAccess:
            "Broad access to protected files. Enable this only when your work requires it; ordinary terminal use does not require allowing every location."
        case .localNetwork:
            "Connect to nearby devices, SSH hosts and development services. macOS asks when the app or program makes a local connection."
        case .microphone:
            "Allow audio input for a feature you choose. Requesting permission here does not start recording; terminal programs can have their own permissions."
        case .screenCapture:
            "For recording or capturing other windows and displays. Screenshots of Tako's own terminal content do not require this access."
        case .systemAudio:
            "For recording sound played by other apps. Ordinary playback and notification sounds are separate from this recording permission."
        case .automation:
            "For scripts that control another app. macOS manages this separately for each target app; only allow commands you intended to run."
        }
    }

    /// Whether this permission can be prompted directly via public Apple APIs.
    public var canRequestDirectly: Bool {
        switch self {
        case .microphone:
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

    var managementSteps: [String] {
        switch self {
        case .fullDiskAccess:
            ["1. Open Full Disk Access in macOS Settings.",
             "2. Press + and choose this copy of Tako using the path below.",
             "3. Turn on its switch. Reopen the app if macOS asks.",
             "A shell or tool named in a separate request needs its own entry; this does not verify all terminal programs."]
        case .protectedFolders:
            ["Choose the folder you actually want to use. macOS handles access to that selection.",
             "The check reads only that folder for this app; it does not prove Full Disk Access or CLI access."]
        case .localNetwork:
            ["Make the local connection you intend to use, such as SSH to your server.",
             "If macOS asks, choose Allow for the app or program named in that prompt.",
             "Review that entry in Local Network settings. Opening Settings alone does not grant access."]
        case .microphone:
            ["Only needed for a voice or recording feature you choose.",
             "Request access for Tako with the button below, or manage the program named by macOS in Microphone settings."]
        case .screenCapture, .systemAudio:
            ["Open Screen & System Audio Recording in macOS Settings.",
             "Press + in the required section and select the app or recording tool you intend to use.",
             "Enable its switch. Tako's own terminal screenshots do not require screen-recording access."]
        case .automation:
            ["Run the script that controls the target app; macOS asks for that specific app.",
             "In Automation settings, expand the requesting program and enable the intended target. There is no blanket permission for every app."]
        }
    }

    var needsAppLocation: Bool {
        self == .fullDiskAccess || self == .screenCapture || self == .systemAudio
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
