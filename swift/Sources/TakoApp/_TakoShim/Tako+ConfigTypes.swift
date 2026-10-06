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
import TakoKit

extension Tako {
    struct ProgressStyle: OptionSet, Sendable, Equatable, ExpressibleByBooleanLiteral {
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(booleanLiteral value: Bool) {
            self = value ? .all : .none
        }

        static let dock = ProgressStyle(rawValue: 1 << 0)
        static let tab = ProgressStyle(rawValue: 1 << 1)
        static let header = ProgressStyle(rawValue: 1 << 2)
        static let window = ProgressStyle(rawValue: 1 << 3)

        static let all: ProgressStyle = [.dock, .tab, .header, .window]
        static let none: ProgressStyle = []

        var showsInDock: Bool { contains(.dock) }
        var showsInTab: Bool { contains(.tab) }
        var showsInHeader: Bool { contains(.header) }
        var showsInWindow: Bool { contains(.window) }

        static func == (lhs: ProgressStyle, rhs: Bool) -> Bool {
            (lhs != .none) == rhs
        }

        static func == (lhs: Bool, rhs: ProgressStyle) -> Bool {
            lhs == (rhs != .none)
        }
    }
}

// MARK: - Nested Configuration Types (Upstream Compatibility)

extension Tako.Config {
    typealias ProgressStyle = Tako.ProgressStyle
    typealias AutoUpdateChannel = Tako.AutoUpdateChannel

    /// Window titlebar style options for macOS windows.
    enum MacOSTitlebarStyle: String, Sendable, CaseIterable {
        static let `default` = MacOSTitlebarStyle.transparent
        case native, transparent, tabs, hidden
    }

    /// Background blur configuration mapping from C/Rust blur parameters.
    enum BackgroundBlur: Equatable, Sendable {
        case disabled
        case radius(Int)
        case macosGlassRegular
        case macosGlassClear

        init(fromCValue value: Int16) {
            switch value {
            case 0:
                self = .disabled
            case -1:
                if #available(macOS 26.0, *) {
                    self = .macosGlassRegular
                } else {
                    self = .disabled
                }
            case -2:
                if #available(macOS 26.0, *) {
                    self = .macosGlassClear
                } else {
                    self = .disabled
                }
            default:
                self = .radius(Int(value))
            }
        }

        var isEnabled: Bool {
            switch self {
            case .disabled:
                return false
            default:
                return true
            }
        }

        var isGlassStyle: Bool {
            switch self {
            case .macosGlassRegular, .macosGlassClear:
                return true
            default:
                return false
            }
        }

        var radius: Int? {
            switch self {
            case .disabled:
                return nil
            case .radius(let r):
                return r
            case .macosGlassRegular, .macosGlassClear:
                return nil
            }
        }
    }

    /// Options for preserving pane zoom levels during navigation.
    struct SplitPreserveZoom: OptionSet, Sendable {
        let rawValue: CUnsignedInt
        static let navigation = SplitPreserveZoom(rawValue: 1 << 0)

        init(rawValue: CUnsignedInt = 0) {
            self.rawValue = rawValue
        }
    }

    /// Terminal bell notification options.
    struct BellFeatures: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let system = BellFeatures(rawValue: 1 << 0)
        static let audio = BellFeatures(rawValue: 1 << 1)
        static let attention = BellFeatures(rawValue: 1 << 2)
        static let title = BellFeatures(rawValue: 1 << 3)
        static let border = BellFeatures(rawValue: 1 << 4)

        init(rawValue: CUnsignedInt = 0) {
            self.rawValue = rawValue
        }
    }

    /// File drop action for macOS dock icon.
    enum MacDockDropBehavior: String, Sendable {
        case new_tab = "new-tab"
        case new_window = "new-window"
    }

    /// Dock visibility setting for macOS app.
    enum MacHidden: String, Sendable {
        case never
        case always
    }

    /// Scrollbar visibility policy.
    enum Scrollbar: String, Sendable {
        case system
        case never
    }

    /// Trigger rule for pane resize dimensions overlay.
    enum ResizeOverlay: String, Sendable {
        case always
        case never
        case after_first = "after-first"
    }

    /// Screen position alignment for resize overlay.
    enum ResizeOverlayPosition: String, Sendable {
        case center
        case top_left = "top-left"
        case top_center = "top-center"
        case top_right = "top-right"
        case bottom_left = "bottom-left"
        case bottom_center = "bottom-center"
        case bottom_right = "bottom-right"

        func top() -> Bool {
            switch self {
            case .top_left, .top_center, .top_right: return true
            default: return false
            }
        }

        func bottom() -> Bool {
            switch self {
            case .bottom_left, .bottom_center, .bottom_right: return true
            default: return false
            }
        }

        func left() -> Bool {
            switch self {
            case .top_left, .bottom_left: return true
            default: return false
            }
        }

        func right() -> Bool {
            switch self {
            case .top_right, .bottom_right: return true
            default: return false
            }
        }
    }

    /// Window decoration mode.
    enum WindowDecoration: String, Sendable {
        case none
        case client
        case server
        case auto

        func enabled() -> Bool {
            switch self {
            case .client, .server, .auto: return true
            case .none: return false
            }
        }
    }

    /// Notification trigger policy upon command completion.
    enum NotifyOnCommandFinish: String, Sendable {
        case never
        case unfocused
        case always
    }

    /// Action performed when command finish notification triggers.
    struct NotifyOnCommandFinishAction: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let bell = NotifyOnCommandFinishAction(rawValue: 1 << 0)
        static let notify = NotifyOnCommandFinishAction(rawValue: 1 << 1)

        init(rawValue: CUnsignedInt = 1) {
            self.rawValue = rawValue
        }

        /// Upstream's syntax: each word turns an action on, its `no-` form
        /// off, starting from `bell`. Unknown words are ignored.
        init(parsing text: String?) {
            var actions: NotifyOnCommandFinishAction = .bell
            for word in (text ?? "").split(separator: ",") {
                switch word.trimmingCharacters(in: .whitespaces).lowercased() {
                case "bell": actions.insert(.bell)
                case "no-bell": actions.remove(.bell)
                case "notify": actions.insert(.notify)
                case "no-notify": actions.remove(.notify)
                default: break
                }
            }
            self = actions
        }
    }
}

// MARK: - Supporting Types for Tako Namespace

extension Tako {
    typealias MacOSTitlebarStyle = Tako.Config.MacOSTitlebarStyle
    typealias BackgroundBlur = Tako.Config.BackgroundBlur
    typealias Scrollbar = Tako.Config.Scrollbar
    typealias WindowDecoration = Tako.Config.WindowDecoration
    typealias NotifyOnCommandFinish = Tako.Config.NotifyOnCommandFinish
    typealias NotifyOnCommandFinishAction = Tako.Config.NotifyOnCommandFinishAction

    /// Config path descriptor.
    struct ConfigPath: Sendable {
        let path: String
        let optional: Bool
    }

    /// Icon choices for the macOS app.
    ///
    /// Upstream's eight artwork variants and its "custom-style" colorized
    /// ghost (upstream's own trademarked mark) are not offered here.
    /// `custom-style` remains as a key, but draws Tako's own mark instead
    /// (see `CustomStyleIcon.swift`). An unrecognised value falls back to
    /// `official`.
    enum MacOSIcon: String, Sendable {
        case official
        case custom
        case customStyle = "custom-style"

        /// No variant ships an asset of its own any more; the app icon comes
        /// from the bundle, `.custom` from the user's own file, and
        /// `.customStyle` is drawn at runtime.
        var assetName: String? { nil }
    }

    /// Icon frame material for custom app icons.
    enum MacOSIconFrame: String, Codable, Sendable {
        case aluminum
        case beige
        case plastic
        case chrome
    }

    /// Window titlebar button visibility.
    enum MacOSWindowButtons: String, Sendable {
        case visible
        case hidden
    }

    /// Proxy icon visibility in window titlebar.
    enum MacOSTitlebarProxyIcon: String, Sendable {
        case visible
        case hidden
    }

    /// Update channel preference.
    enum AutoUpdateChannel: String, Sendable {
        case stable
        case tip
    }

    // FullscreenMode is declared by the app layer (Helpers/Fullscreen.swift).

    // QuickTerminalScreen, QuickTerminalSpaceBehavior and QuickTerminalSize
    // are declared by the app layer; a second copy here only made the
    // config's values incompatible with the properties they feed.

    /// Command palette entry descriptor.
    struct Command: Sendable, Equatable {
        let title: String
        let description: String
        let action: String
        let actionKey: String

        /// Only actions this port can carry out are offered; see
        /// `Tako.SurfaceView.performBindingAction`.
        var isSupported: Bool {
            !Self.unsupportedActionKeys.contains(actionKey)
                && Tako.SurfaceView.isBindingActionSupported(action)
        }

        static let unsupportedActionKeys: [String] = [
            "toggle_tab_overview",
            "toggle_window_decorations",
            "show_gtk_inspector",
        ]

        init(title: String = "", description: String = "", action: String = "", actionKey: String = "") {
            self.title = title
            self.description = description
            self.action = action
            self.actionKey = actionKey
        }
    }
}
