import SwiftUI

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        @Binding var split: CGFloat

        private var visibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        private var pointerStyle: BackportPointerStyle {
            return switch direction {
            case .horizontal: .resizeLeftRight
            case .vertical: .resizeUpDown
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle()) // Makes it hit testable for pointerStyle
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
            }
            .backport.pointerStyle(pointerStyle)
            .onHover { isHovered in
                SplitDivider.updateCursor(hovered: isHovered, direction: direction)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                split = SplitDivider.adjusted(split, by: direction)
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return "Horizontal split divider"
            case .vertical:
                return "Vertical split divider"
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return "Drag to resize the left and right panes"
            case .vertical:
                return "Drag to resize the top and bottom panes"
            }
        }
    }
}

/// What the divider does, apart from the view, so it can be tested without
/// hover or VoiceOver events.
enum SplitDivider {
    /// VoiceOver's increment and decrement: 2.5% a step, kept within
    /// 10...90% so neither pane can vanish.
    static func adjusted(_ split: CGFloat, by direction: AccessibilityAdjustmentDirection) -> CGFloat {
        let adjustment: CGFloat = 0.025
        switch direction {
        case .increment:
            return min(split + adjustment, 0.9)
        case .decrement:
            return max(split - adjustment, 0.1)
        @unknown default:
            return split
        }
    }

    /// On macOS 15 and later `pointerStyle` shows the resize cursor, which
    /// is much less error-prone; macOS 14 needs the cursor pushed and popped
    /// by hand.
    static func updateCursor(hovered: Bool, direction: SplitViewDirection) {
        if #available(macOS 15, *) {
            return
        }

        if hovered {
            switch direction {
            case .horizontal:
                NSCursor.resizeLeftRight.push()
            case .vertical:
                NSCursor.resizeUpDown.push()
            }
        } else {
            NSCursor.pop()
        }
    }
}
