/*
 * tako — Terminal permission inspection and request service
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// Inspects and manages macOS system permissions for Tako and terminal sessions using public Apple APIs.
@MainActor
public final class TerminalPermissionService: ObservableObject {
    public typealias AuthorizationHandler = @MainActor @Sendable (AVMediaType) -> AVAuthorizationStatus
    public typealias CheckHandler = @MainActor @Sendable (TerminalPermissionKind) async -> TerminalPermissionStatus?
    public typealias ScreenCaptureCheck = @MainActor @Sendable () -> Bool
    public typealias RequestHandler = @MainActor @Sendable (AVMediaType) async -> Bool
    public typealias OpenHandler = @MainActor @Sendable (URL) -> Bool

    @Published public private(set) var permissions: [TerminalPermission] = []

    /// Current permission rows, ordered consistently by TerminalPermissionKind.
    public var rows: [TerminalPermission] { permissions }

    private let authorization: AuthorizationHandler
    private let check: CheckHandler?
    private let screenCaptureCheck: ScreenCaptureCheck
    private let screenCaptureRequest: ScreenCaptureCheck
    private let requestAccess: RequestHandler
    private let open: OpenHandler

    public init(
        authorization: @escaping AuthorizationHandler = { AVCaptureDevice.authorizationStatus(for: $0) },
        check: CheckHandler? = nil,
        screenCaptureCheck: @escaping ScreenCaptureCheck = { CGPreflightScreenCaptureAccess() },
        screenCaptureRequest: @escaping ScreenCaptureCheck = { CGRequestScreenCaptureAccess() },
        request: @escaping RequestHandler = { await AVCaptureDevice.requestAccess(for: $0) },
        open: @escaping OpenHandler = { NSWorkspace.shared.open($0) }
    ) {
        self.authorization = authorization
        self.check = check
        self.screenCaptureCheck = screenCaptureCheck
        self.screenCaptureRequest = screenCaptureRequest
        self.requestAccess = request
        self.open = open
    }

    /// Evaluates current permission states using public Apple APIs without triggering user prompts or probes.
    @discardableResult
    public func snapshot() async -> [TerminalPermission] {
        var items: [TerminalPermission] = []
        for kind in TerminalPermissionKind.allCases {
            let currentStatus = await status(for: kind)
            items.append(TerminalPermission(kind: kind, status: currentStatus))
        }
        self.permissions = items
        return items
    }

    /// Returns the current permission status for a specific kind without prompting.
    public func status(for kind: TerminalPermissionKind) async -> TerminalPermissionStatus {
        if let custom = await check?(kind) {
            return custom
        }

        switch kind {
        case .microphone:
            return mapAVStatus(authorization(.audio))
        case .screenCapture:
            // CGPreflightScreenCaptureAccess only returns true (allowed) or false (not allowed).
            // It cannot distinguish between denied and not yet asked. We report notAllowed honestly.
            return screenCaptureCheck() ? .allowed : .notAllowed
        case .protectedFolders, .fullDiskAccess, .localNetwork, .systemAudio, .automation:
            // Public macOS APIs cannot preflight these permissions without intrusive probes
            // (e.g. accessing protected directories, sending network probes, or starting audio recording).
            // We report managedInSettings honestly without performing any disk, TCC, or network probing.
            return .managedInSettings
        }
    }

    /// Convenient alias for status inspection.
    public func check(_ kind: TerminalPermissionKind) async -> TerminalPermissionStatus {
        await status(for: kind)
    }

    /// Convenient alias with named argument for status inspection.
    public func check(kind: TerminalPermissionKind) async -> TerminalPermissionStatus {
        await status(for: kind)
    }

    /// Looks up a cached permission model from the most recent snapshot.
    public func permission(for kind: TerminalPermissionKind) -> TerminalPermission? {
        permissions.first { $0.kind == kind }
    }

    /// Explicitly requests microphone or screen access without recording.
    /// Refuses unsupported kinds without prompting.
    public func request(_ kind: TerminalPermissionKind) async -> TerminalPermissionRequestResult {
        if kind == .screenCapture {
            let current = await status(for: kind)
            if current == .allowed {
                return TerminalPermissionRequestResult(kind: kind, status: .allowed,
                    message: "Screen Recording access is already allowed.", didPrompt: false)
            }
            let granted = screenCaptureRequest()
            let fetched = await status(for: kind)
            let updated: TerminalPermissionStatus = granted ? .allowed : fetched
            if let index = permissions.firstIndex(where: { $0.kind == kind }) {
                permissions[index] = TerminalPermission(kind: kind, status: updated)
            }
            return TerminalPermissionRequestResult(kind: kind, status: updated,
                message: updated == .allowed ? "Screen Recording access granted."
                    : "Enable Tako in Screen Recording settings. Reopen if macOS asks.", didPrompt: true)
        }
        guard kind.canRequestDirectly, let mediaType = kind.mediaType else {
            let current = await status(for: kind)
            let message = "\(kind.title) cannot be requested directly. Open System Settings to manage access."
            return TerminalPermissionRequestResult(
                kind: kind,
                status: current,
                message: message,
                didPrompt: false
            )
        }

        let initialStatus = await status(for: kind)
        if initialStatus == .allowed {
            return TerminalPermissionRequestResult(
                kind: kind,
                status: .allowed,
                message: "\(kind.title) access is already allowed.",
                didPrompt: false
            )
        }
        if initialStatus == .denied || initialStatus == .restricted {
            return TerminalPermissionRequestResult(kind: kind, status: initialStatus,
                message: "\(kind.title) access is \(initialStatus.title.lowercased()). Manage it in System Settings.",
                didPrompt: false)
        }

        let granted = await requestAccess(mediaType)
        let fetched = await status(for: kind)
        let updatedStatus: TerminalPermissionStatus
        if fetched == .notAsked {
            updatedStatus = granted ? .allowed : .denied
        } else {
            updatedStatus = fetched
        }

        if let index = permissions.firstIndex(where: { $0.kind == kind }) {
            permissions[index] = TerminalPermission(kind: kind, status: updatedStatus)
        }

        let message: String
        switch updatedStatus {
        case .allowed:
            message = "\(kind.title) access granted."
        case .denied:
            message = "\(kind.title) access was denied. You can enable it in System Settings."
        case .restricted:
            message = "\(kind.title) access is restricted by system policy."
        case .notAsked:
            message = "\(kind.title) access has not been determined."
        case .notAllowed:
            message = "\(kind.title) access is not allowed."
        case .managedInSettings:
            message = "\(kind.title) is managed in System Settings."
        case .unknown:
            message = "\(kind.title) authorization status is unknown."
        }

        return TerminalPermissionRequestResult(
            kind: kind,
            status: updatedStatus,
            message: message,
            didPrompt: true
        )
    }

    /// Explicitly requests access with named argument.
    public func request(kind: TerminalPermissionKind) async -> TerminalPermissionRequestResult {
        await request(kind)
    }

    /// Opens the corresponding System Settings pane for the given permission kind.
    @discardableResult
    public func openSettings(_ kind: TerminalPermissionKind) -> Bool {
        guard let url = kind.settingsURL ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else {
            return false
        }
        return open(url)
    }

    /// Opens the corresponding System Settings pane with named argument.
    @discardableResult
    public func openSettings(kind: TerminalPermissionKind) -> Bool {
        openSettings(kind)
    }

    /// Default live instance configured with system framework bindings.
    public static func live() -> TerminalPermissionService {
        TerminalPermissionService()
    }

    private func mapAVStatus(_ avStatus: AVAuthorizationStatus) -> TerminalPermissionStatus {
        switch avStatus {
        case .authorized:
            return .allowed
        case .denied:
            return .denied
        case .notDetermined:
            return .notAsked
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }
}
