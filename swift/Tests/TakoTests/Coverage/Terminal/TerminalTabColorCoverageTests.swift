import Testing
import AppKit
import SwiftUI
@testable import Tako

@MainActor
struct TerminalTabColorCoverageTests {
    @Test func localizedNameCoversEveryCase() {
        func expectedName(for color: TerminalTabColor) -> String {
            switch color {
            case .none: return "None"
            case .blue: return "Blue"
            case .purple: return "Purple"
            case .pink: return "Pink"
            case .red: return "Red"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .teal: return "Teal"
            case .graphite: return "Graphite"
            }
        }
        for color in TerminalTabColor.allCases {
            #expect(color.localizedName == expectedName(for: color))
        }
    }

    @Test func displayColorIsNilOnlyForNone() {
        for color in TerminalTabColor.allCases {
            if color == .none {
                #expect(color.displayColor == nil)
            } else {
                #expect(color.displayColor != nil)
            }
        }
    }

    @Test func swatchImageRendersForEveryColorSelectedAndUnselected() {
        for color in TerminalTabColor.allCases {
            let unselected = color.swatchImage(selected: false)
            let selected = color.swatchImage(selected: true)
            #expect(unselected.size.width == 18)
            #expect(selected.size.width == 18)
        }
    }

    @Test func codableRoundTrips() throws {
        for color in TerminalTabColor.allCases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(TerminalTabColor.self, from: data)
            #expect(decoded == color)
        }
    }

    @Test func tabColorMenuViewBuildsAndReportsSelection() {
        var selected: TerminalTabColor?
        let view = TabColorMenuView(selectedColor: .blue) { color in
            selected = color
        }
        _ = view.body
        #expect(TabColorMenuView.paletteRows.count == 2)
        #expect(TabColorMenuView.paletteRows[0].contains(.blue))
        #expect(selected == nil)
    }

    @Test func tabColorMenuViewRendersEverySwatchWhenHosted() {
        for selected in TerminalTabColor.allCases {
            let view = TabColorMenuView(selectedColor: selected) { _ in }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            #expect(hosting.fittingSize.width > 0)
        }
    }
}
