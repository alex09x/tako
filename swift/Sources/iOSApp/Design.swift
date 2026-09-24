import SwiftUI

// The numbers from the design, in one place.
//
// Everything here is quoted from "Mobile UI.dc.html" — sizes in pt at @1x,
// colours as the brand sheet names them. Kept as tokens rather than spread
// through the views so a spec change is a diff here, not a hunt.

enum Metric {
    /// Screen headers: 48 tall, hairline underneath.
    static let headerHeight: CGFloat = 48
    /// A touch target below 44 is one the design does not have.
    static let hit: CGFloat = 44

    enum Card {
        static let radius: CGFloat = 14
        static let padding: CGFloat = 16
        static let gap: CGFloat = 10
        static let inset: CGFloat = 16
        static let titleSize: CGFloat = 14
        static let subtitleSize: CGFloat = 12
        static let titleGap: CGFloat = 3
        static let statusDot: CGFloat = 8
    }

    enum Sheet {
        static let radius: CGFloat = 22
        static let handleWidth: CGFloat = 40
        static let handleHeight: CGFloat = 5
        static let handleGap: CGFloat = 14
        static let itemRadius: CGFloat = 14
        static let itemPadding: CGFloat = 16
        static let titleSize: CGFloat = 16
        static let titleGap: CGFloat = 14
    }

    enum Field {
        static let height: CGFloat = 48
        static let radius: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
        static let textSize: CGFloat = 14
        static let labelSize: CGFloat = 11
        static let labelTracking: CGFloat = 0.08 * 11
        static let labelGap: CGFloat = 6
    }

    enum Submit {
        static let height: CGFloat = 52
        static let radius: CGFloat = 14
        static let textSize: CGFloat = 15
    }

    enum Keys {
        static let height: CGFloat = 44
        static let gap: CGFloat = 6
        static let rowPaddingV: CGFloat = 8
        static let rowPaddingH: CGFloat = 10
        static let radius: CGFloat = 9
        static let glyphSize: CGFloat = 13
    }

    /// The terminal grid.
    enum Terminal {
        /// Column zero is otherwise painted into the screen edge, and a glyph
        /// whose left bearing is negative -- `a` in this font, on the prompt
        /// -- gets its first pixels clipped away. Matching the key row's
        /// padding also lines the text up with the keys under it.
        static let inset: CGFloat = Keys.rowPaddingH
    }

    /// The wordmark block at the top of the session list.
    enum Wordmark {
        static let markSize: CGFloat = 26
        static let textSize: CGFloat = 20
        static let tracking: CGFloat = 0.6
        static let topInset: CGFloat = 18
        static let leadingInset: CGFloat = 20
    }
}

extension Brand {
    /// The ember gradient the primary buttons use: 160°, ember into rust.
    static var emberGradient: LinearGradient {
        LinearGradient(
            colors: [ember, rust],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Sheet edge, field border and segment container all share this.
    static let stroke = Color(red: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255)
    /// The tint under a pressed or active key.
    static let keyActive = Color(red: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255)
    /// Body text that is neither bright nor dim.
    static let bodyMuted = Color(red: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255)
    /// The destructive swipe zone, and a changed host key.
    static let danger = Color(red: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255)
    /// The scrim behind a sheet.
    static let scrim = Color(red: 0x0A / 255, green: 0x08 / 255, blue: 0x07 / 255).opacity(0.6)
}

/// JetBrains Mono is the whole UI, not just the terminal, per the brand
/// sheet. It is bundled with the app; falling back to the system monospace
/// keeps a missing font from turning into a missing screen.
enum Mono {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A haptic tap. The design asks for one on every key and on the primary
/// actions; wrapping it keeps `UIImpactFeedbackGenerator` out of the views.
enum Haptic {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func commit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func warn() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
