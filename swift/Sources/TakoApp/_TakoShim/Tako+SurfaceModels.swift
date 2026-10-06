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
import SwiftUI
import TakoKit

extension Tako {
    // MARK: - Delegate Protocol
    /// Protocol implemented by the main AppDelegate to look up active surface views by UUID.
    public protocol Delegate: AnyObject {
        func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView?
    }

    /// Payloads the core sends up with an app action. Upstream generates
    /// these from its Zig definitions; ours carry the same fields.
    public enum Action {
        /// Move the current tab left (negative) or right (positive).
        public struct MoveTab {
            public let amount: Int
            public init(amount: Int) { self.amount = amount }
        }

        /// OSC 9;4 progress, shown in the dock and the tab title.
        public struct ProgressReport: Equatable {
            public enum State: Equatable { case none, set, error, indeterminate, pause }
            public let state: State
            public let progress: UInt8?
            public init(state: State, progress: UInt8? = nil) {
                self.state = state
                self.progress = progress
            }
        }

        /// Scrollbar visibility policy.
        public typealias Scrollbar = Tako.Config.Scrollbar

        public struct StartSearch {
            public let needle: String?

            public init(needle: String?) {
                self.needle = needle
            }

            public init(c: tako_action_start_search_s) {
                if let needleCString = c.needle {
                    self.needle = String(cString: needleCString)
                } else {
                    self.needle = nil
                }
            }
        }
    }

    /// Make `to` the first responder of its window, optionally after a delay
    /// so it runs behind any UI that is still restoring focus itself.
    @MainActor public static func moveFocus(
        to: SurfaceView?,
        from: SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        guard let to else { return }
        let move = {
            guard let window = to.window else { return }
            window.makeFirstResponder(to)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: move)
        } else {
            move()
        }
    }

    public struct SurfaceConfiguration {
        public var fontSize: Float32?
        public var workingDirectory: String?
        public var command: String?
        public var initialInput: String?
        /// Hold the surface open after the command exits, so a script that
        /// finishes instantly doesn't flash the window closed.
        public var waitAfterCommand: Bool = false
        public var environmentVariables: [String: String] = [:]
        /// What the surface showed before a relaunch, painted before its new
        /// shell starts. Set only when a window is restored.
        var restoredSnapshot: SessionSnapshot?
        /// Set when the surface is being restored with a window, so a
        /// persistent session is checked rather than created.
        var isRestored = false
        /// The saved surface said its shell lived in a persistent session.
        var hadPersistentSession = false
        /// A program to run in place of the login shell, argv as given:
        /// `takoctl run`. The pane is not put in a persistent session, and
        /// it stays open with the program's output after it exits.
        var program: [String]?
        /// False for terminals that are never restored (the quick terminal):
        /// their shell is not put in a session that would outlive Tako.
        var allowsSessionPersistence = true

        public init() {}

        public init(fontSize: Float32? = nil,
                    workingDirectory: String? = nil,
                    command: String? = nil,
                    initialInput: String? = nil,
                    waitAfterCommand: Bool = false,
                    environmentVariables: [String: String] = [:]) {
            self.fontSize = fontSize
            self.workingDirectory = workingDirectory
            self.command = command
            self.initialInput = initialInput
            self.waitAfterCommand = waitAfterCommand
            self.environmentVariables = environmentVariables
        }
    }

    public class Inspector: ObservableObject {
        public init() {}
    }

    public struct ChildExitedMessage {
        public var message: String
        public init(message: String) { self.message = message }
    }
}

/// Upstream's AppDelegate declares conformance to this; it is the protocol
/// its app-level code calls back into.
protocol TakoAppDelegate: AnyObject {
    func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView?
}

extension TakoAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView? { nil }
}

/// A value that is expensive to compute and is asked for more than once.
/// It is recomputed only after `invalidate()`.
public final class CachedValue<T> {
    private let compute: () -> T
    private var cached: T?

    public init(_ compute: @escaping () -> T) {
        self.compute = compute
    }

    public func get() -> T {
        if let cached { return cached }
        let value = compute()
        cached = value
        return value
    }

    public func invalidate() {
        cached = nil
    }
}

extension Tako.SurfaceView {
        struct DerivedConfig: Equatable {
            let backgroundColor: Color
            let backgroundOpacity: Double
            let backgroundBlur: Tako.Config.BackgroundBlur
            let macosWindowShadow: Bool
            let windowTitleFontFamily: String?
            let windowAppearance: NSAppearance?
            let scrollbar: Tako.Action.Scrollbar

            init() {
                self.backgroundColor = Color(nsColor: .windowBackgroundColor)
                self.backgroundOpacity = 1.0
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            init(_ config: Tako.Config) {
                self.backgroundColor = config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
                self.backgroundBlur = config.backgroundBlur
                self.macosWindowShadow = config.macosWindowShadow
                self.windowTitleFontFamily = config.windowTitleFontFamily
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            static func == (lhs: DerivedConfig, rhs: DerivedConfig) -> Bool {
                lhs.backgroundColor == rhs.backgroundColor &&
                lhs.backgroundOpacity == rhs.backgroundOpacity &&
                lhs.macosWindowShadow == rhs.macosWindowShadow &&
                lhs.windowTitleFontFamily == rhs.windowTitleFontFamily
            }
        }

}
