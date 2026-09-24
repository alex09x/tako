import SwiftUI

/// What a saved or half-typed ssh host looks like on its way through the UI.
///
/// Identifiable so a navigation destination can be driven by it directly:
/// picking a recent host and opening the form are then the same action with
/// different starting values.
struct SshDraft: Identifiable, Equatable, Hashable {
    var id = UUID()
    var host: String = ""
    var username: String = ""
    var port: String = "22"
    var usesKey: Bool = true
    var privateKeyPEM: String = ""
    var passphrase: String = ""
    var password: String = ""

    /// The form's submit button is dead until this is true. A host with no
    /// name or no user cannot be connected to, and saying so by staying grey
    /// beats an error after the fact.
    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (UInt16(port) ?? 0) > 0
    }

    var subtitle: String {
        let port = self.port == "22" ? "" : ":\(self.port)"
        return username.isEmpty ? "\(host)\(port)" : "\(username)@\(host)\(port)"
    }
}

/// The sheet that comes up from the bottom: an interactive in-process demo,
/// a new SSH host, or one you have reached before.
struct NewSessionSheet: View {
    let recents: [SshDraft]
    let onLocal: () -> Void
    let onNewHost: () -> Void
    let onRecent: (SshDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            handle

            Text("New session")
                .font(Mono.font(Metric.Sheet.titleSize, weight: .bold))
                .foregroundColor(Brand.paper)
                .padding(.bottom, Metric.Sheet.titleGap)

            choice(
                glyph: "❯_",
                glyphColor: Brand.ember,
                // Not an OS shell: iOS gives an app no fork/exec. A small
                // in-process peer still provides normal line editing,
                // Return and deterministic commands so the terminal can be
                // tried honestly without a server.
                title: "Interactive demo",
                subtitle: "type help · runs in process",
                identifier: "choice.demo",
                action: onLocal
            )
            .padding(.bottom, 10)

            choice(
                glyph: "ssh",
                glyphColor: Brand.claw,
                title: "SSH host",
                subtitle: "key or password",
                identifier: "choice.ssh",
                action: onNewHost
            )

            if !recents.isEmpty {
                Text("RECENT")
                    .font(Mono.font(Metric.Field.labelSize))
                    .tracking(Metric.Field.labelTracking)
                    .foregroundColor(Brand.dim)
                    .padding(.top, 22)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, draft in
                        Button {
                            Haptic.tap()
                            onRecent(draft)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Brand.dim)
                                    .frame(width: Metric.Card.statusDot, height: Metric.Card.statusDot)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.host)
                                        .font(Mono.font(13))
                                        .foregroundColor(Brand.paper)
                                    Text(draft.subtitle)
                                        .font(Mono.font(11))
                                        .foregroundColor(Brand.dim)
                                }
                                Spacer()
                                Text("›").foregroundColor(Brand.dim)
                            }
                            .frame(height: Metric.hit)
                        }
                        .buttonStyle(.plain)

                        if index < recents.count - 1 {
                            Rectangle().fill(Brand.hairline).frame(height: 1)
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(Mono.font(Metric.Field.textSize))
                    .foregroundColor(Brand.bodyMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metric.Field.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metric.Sheet.itemRadius, style: .continuous)
                            .stroke(Brand.stroke, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, Metric.Card.inset)
        .padding(.top, 10)
        .padding(.bottom, 30)
        .background(Brand.ink)
    }

    private var handle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Brand.stroke)
                .frame(width: Metric.Sheet.handleWidth, height: Metric.Sheet.handleHeight)
            Spacer()
        }
        .padding(.bottom, Metric.Sheet.handleGap)
    }

    private func choice(
        glyph: String,
        glyphColor: Color,
        title: String,
        subtitle: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                Text(glyph)
                    .font(Mono.font(15, weight: .bold))
                    .foregroundColor(glyphColor)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: Metric.Card.titleGap) {
                    Text(title)
                        .font(Mono.font(Metric.Card.titleSize))
                        .foregroundColor(Brand.paper)
                    Text(subtitle)
                        .font(Mono.font(Metric.Card.subtitleSize))
                        .foregroundColor(Brand.dim)
                }
                Spacer()
                Text("›").foregroundColor(Brand.dim)
            }
            .padding(Metric.Sheet.itemPadding)
            .frame(minHeight: Metric.hit)
            .background(Brand.keyActive)
            .clipShape(RoundedRectangle(cornerRadius: Metric.Sheet.itemRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        // The row is a stack of several Texts, so its accessibility label is
        // the lot of them run together and useless to address. See ios/UITests.
        .accessibilityIdentifier(identifier)
    }
}
