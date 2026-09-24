import SwiftUI

// All backport view modifiers go as an extension on this. We use this so we
// can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Backport where Content: View {
    /// `pointerStyle` is macOS 15+; the app runs on 14, where the pointer
    /// keeps its default shape.
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .columnResize(directions: .leading)
        case .resizeRight: return .columnResize(directions: .trailing)
        case .resizeUp: return .rowResize(directions: .up)
        case .resizeDown: return .rowResize(directions: .down)
        case .resizeUpDown: return .rowResize
        case .resizeLeftRight: return .columnResize
        }
    }
    #endif
}

enum BackportNSGlassStyle {
    case regular, clear

    #if canImport(AppKit)
    @available(macOS 26, *)
    var official: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
    #endif
}
