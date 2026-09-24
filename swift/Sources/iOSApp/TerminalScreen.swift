import SwiftUI
import UIKit

// One session, full screen: the terminal, and the key row a phone keyboard
// does not have.

/// Draws the engine's atomic frame with the shared Metal renderer. UIKit
/// hosts the CAMetalLayer and input surface; CoreText is only the no-Metal
/// fallback and the source of rasterized glyph atlas entries.
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var session: Session

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TakoTerminalView {
        let view = TakoTerminalView(core: session.core)
        view.delegate = context.coordinator
        session.surface = view
        return view
    }

    func updateUIView(_ view: TakoTerminalView, context: Context) {
        context.coordinator.session = session
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, TakoTerminalViewDelegate {
        var session: Session

        init(session: Session) {
            self.session = session
        }

        func terminalView(_ view: TakoTerminalView, sendInputData data: Data) {
            session.sendInput(session.keyRow.applyingControl(to: data))
        }

        func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {
            session.sendDeviceReply(data)
        }

        func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {
            session.handleResize(cols: cols, rows: rows)
        }

        func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {
            session.title = title
        }

        func terminalViewDidBell(_ view: TakoTerminalView) {
            session.handleBell()
            Haptic.warn()
        }

        func terminalViewCommandDidStart(_ view: TakoTerminalView) {
            session.commandDidStart()
        }

        func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {
            session.commandDidEnd(exitCode: exitCode)
        }

        /// A program on the far end asked for the clipboard. On a phone the
        /// pasteboard is shared with every other app, so this is the user's
        /// call, not the remote program's -- and for now the answer is no.
        func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String) {}
    }
}

struct TerminalScreen: View {
    @ObservedObject var session: Session
    @Environment(\.dismiss) private var dismiss

    /// Held by the session rather than this view so a scripted run presses
    /// the same keys through the same code, rather than a copy of it.
    @ObservedObject private var keys: KeyRow

    init(session: Session) {
        self.session = session
        self.keys = session.keyRow
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            connectionNotice
            TerminalSurface(session: session)
                .padding(.horizontal, Metric.Terminal.inset)
                .background(Brand.surface)
            keyRow
        }
        .background(Brand.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(
            item: $session.authenticationChallenge,
            onDismiss: session.restoreTerminalFocusAfterAuthentication
        ) { challenge in
            AuthenticationChallengeSheet(
                challenge: challenge,
                onSubmit: session.submitAuthenticationChallenge,
                onCancel: session.cancelAuthenticationChallenge
            )
            // SwiftUI can reuse the presented sheet while the SSH server
            // advances to another round. Force fresh fields for the new id.
            .id(challenge.id)
        }
        .onDisappear { session.surfaceWentAway() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Text("‹")
                    .font(Mono.font(20, weight: .bold))
                    .foregroundColor(Brand.ember)
                    .frame(width: Metric.hit, height: Metric.hit, alignment: .leading)
            }
            .accessibilityLabel("Sessions")
            .accessibilityIdentifier("terminal.back")

            CrabMark(size: 18)

            Text(session.title)
                .font(Mono.font(13))
                .foregroundColor(Brand.paper)
                .lineLimit(1)

            Circle()
                .fill(session.statusColor)
                .frame(width: 7, height: 7)

            Spacer()

            Text("＋")
                .font(Mono.font(18))
                .foregroundColor(Brand.dim)
                .frame(width: Metric.hit, height: Metric.hit)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: Metric.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.hairline).frame(height: 1)
        }
    }

    private var keyRow: some View {
        HStack(spacing: Metric.Keys.gap) {
            ForEach(KeyRow.keys, id: \.self) { key in
                keyButton(key)
            }
        }
        .padding(.horizontal, Metric.Keys.rowPaddingH)
        .padding(.vertical, Metric.Keys.rowPaddingV)
        .background(Brand.ink)
        .overlay(alignment: .top) {
            Rectangle().fill(Brand.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private var connectionNotice: some View {
        switch session.status {
        case .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Brand.claw)
                Text("connecting…")
            }
            .font(Mono.font(11))
            .foregroundColor(Brand.bodyMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.Terminal.inset)
            .frame(minHeight: 28)
            .background(Brand.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("session.status")
        case .disconnected(let reason):
            HStack(spacing: 8) {
                Circle().fill(Brand.error).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("disconnected · \(reason)")
                    .lineLimit(2)
            }
            .font(Mono.font(11))
            .foregroundColor(Brand.bodyMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.Terminal.inset)
            .padding(.vertical, 6)
            .background(Brand.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("session.status")
        }
    }

    private func colour(for key: String) -> Color {
        if key == KeyRow.control && keys.controlArmed { return Brand.ember }
        if key == "paste" { return Brand.claw }
        return Brand.text
    }

    private func background(for key: String) -> Color {
        if key == KeyRow.control && keys.controlArmed { return Brand.keyActive }
        if key == "paste" { return Brand.keyAccent }
        return Brand.key
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key == KeyRow.paste {
            ZStack {
                // PasteButton remains the real, fully hittable control: iOS
                // recognises it as an explicit user paste gesture and does
                // not raise the clipboard permission prompt. The branded
                // artwork below is drawn *over* it without accepting hits,
                // so it hides the system-blue chrome without making the
                // native control transparent (which disables its callback).
                PasteButton(payloadType: String.self) { strings in
                    Haptic.tap()
                    guard let text = strings.first, !text.isEmpty else { return }
                    session.sendInput(Data(session.core.encodePaste(text: text)))
                }
                .labelStyle(.titleOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel("Paste")
                .accessibilityIdentifier("key.paste")

                RoundedRectangle(cornerRadius: Metric.Keys.radius, style: .continuous)
                    .fill(background(for: key))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Text(key)
                    .font(Mono.font(12, weight: .bold))
                    .foregroundColor(colour(for: key))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metric.Keys.height)
        } else {
            Button {
                Haptic.tap()
                press(key)
            } label: {
                Text(key)
                    .font(Mono.font(Metric.Keys.glyphSize))
                    .foregroundColor(colour(for: key))
                    .frame(maxWidth: .infinity)
                    .frame(height: Metric.Keys.height)
                    .background(
                        RoundedRectangle(cornerRadius: Metric.Keys.radius, style: .continuous)
                            .fill(background(for: key))
                    )
            }
            .buttonStyle(.plain)
            // The keys are glyphs, so a name is the only way a UI test can
            // press one. See ios/UITests.
            .accessibilityIdentifier("key.\(KeyRow.name(of: key))")
        }
    }

    private func press(_ key: String) {
        if let bytes = keys.bytes(for: key) {
            session.sendInput(Data(bytes))
        }
    }
}

/// The crab as a dot: the phone has no room for the full mark in a list row.
struct CrabDot: View {
    let state: CrabState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .opacity(state == .idle ? 0.45 : 1)
    }
}
