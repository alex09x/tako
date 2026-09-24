import SwiftUI

/// Where a host is described well enough to connect to.
struct SshFormScreen: View {
    @State var draft: SshDraft
    let onConnect: (SshDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?
    @State private var formScrollPosition: Field?

    private enum Field: Hashable { case host, user, port, password, key, passphrase }

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.ink.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    labelled("HOST") {
                        field("prod-2.internal", text: $draft.host, focus: .host)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }

                    HStack(spacing: 12) {
                        labelled("USER") {
                            field("alex", text: $draft.username, focus: .user)
                                .textInputAutocapitalization(.never)
                        }
                        labelled("PORT") {
                            field("22", text: $draft.port, focus: .port)
                                .keyboardType(.numberPad)
                        }
                        .frame(width: 90)
                    }

                    labelled("AUTHENTICATION") {
                        authSegment
                    }

                    if draft.usesKey {
                        keyField
                        if !draft.privateKeyPEM.isEmpty {
                            keyPassphraseField
                                .id(Field.passphrase)
                        }
                    } else {
                        labelled("PASSWORD") {
                            SecureField("", text: $draft.password)
                                .font(Mono.font(Metric.Field.textSize))
                                .foregroundColor(Brand.text)
                                .padding(.horizontal, Metric.Field.horizontalPadding)
                                .frame(height: Metric.Field.height)
                                .background(fieldBackground(focused: focused == .password))
                                .focused($focused, equals: .password)
                                .accessibilityIdentifier("field.password")
                        }
                    }

                }
                .padding(.horizontal, Metric.Card.inset)
                .padding(.top, 16)
                .scrollTargetLayout()
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition(id: $formScrollPosition, anchor: .center)
            .onChange(of: draft.privateKeyPEM.isEmpty) { wasEmpty, isEmpty in
                guard wasEmpty && !isEmpty else { return }
                // The passphrase row is inserted below the focused key
                // editor. SwiftUI keeps that editor visible, which used to
                // leave the new row entirely behind the keyboard and submit
                // inset. Reveal the credential as soon as a key appears.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        formScrollPosition = .passphrase
                    }
                }
            }
            // As a safe area inset rather than a sibling pinned over the
            // scroll view. Pinned, it sat on top of whatever the keyboard had
            // just scrolled into view -- which is always the field you are
            // typing into, so the password box was covered by the button that
            // submits it, and a tap aimed at the field pressed Connect.
            .safeAreaInset(edge: .bottom) {
                submit
                    .padding(.horizontal, Metric.Card.inset)
                    .padding(.top, 8)
                    .padding(.bottom, Metric.Card.inset)
                    .background(Brand.ink)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SSH host")
                    .font(Mono.font(Metric.Sheet.titleSize, weight: .bold))
                    .foregroundColor(Brand.paper)
            }
        }
        .toolbarBackground(Brand.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Pieces

    private func labelled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metric.Field.labelGap) {
            Text(label)
                .font(Mono.font(Metric.Field.labelSize))
                .tracking(Metric.Field.labelTracking)
                .foregroundColor(Brand.dim)
            content()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, focus: Field) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Brand.dim.opacity(0.6)))
            .font(Mono.font(Metric.Field.textSize))
            .foregroundColor(Brand.text)
            .autocorrectionDisabled()
            .padding(.horizontal, Metric.Field.horizontalPadding)
            .frame(height: Metric.Field.height)
            .background(fieldBackground(focused: focused == focus))
            .focused($focused, equals: focus)
            // The fields carry no visible label, so this is the only handle a
            // UI test has on them. See ios/UITests.
            .accessibilityIdentifier("field.\(focus)")
    }

    /// Focus is an ember border plus a soft glow, per the spec.
    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
            .fill(Brand.card)
            .overlay(
                RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                    .stroke(focused ? Brand.ember : Brand.stroke, lineWidth: focused ? 1.5 : 1)
            )
            .shadow(color: focused ? Brand.ember.opacity(0.15) : .clear, radius: 3)
    }

    private var authSegment: some View {
        HStack(spacing: 4) {
            segment("key", active: draft.usesKey) { draft.usesKey = true }
            segment("password", active: !draft.usesKey) { draft.usesKey = false }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                .fill(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                        .stroke(Brand.stroke, lineWidth: 1)
                )
        )
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            // The port's number pad has no Return key. Authentication is the
            // next visible step, so choosing either mode also leaves the
            // field and reveals the credential controls below it.
            focused = nil
            Haptic.tap()
            action()
        } label: {
            Text(title)
                .font(Mono.font(13, weight: active ? .bold : .regular))
                .foregroundColor(active ? Brand.claw : Brand.dim)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Brand.keyActive : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("auth.\(title)")
    }

    /// A key is pasted rather than picked: the phone has no file it owns, and
    /// generating one in the Secure Enclave is its own screen in the design.
    private var keyField: some View {
        labelled("PRIVATE KEY") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft.privateKeyPEM)
                    .font(Mono.font(11))
                    .foregroundColor(Brand.text)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(height: 96)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(fieldBackground(focused: focused == .key))
                    .focused($focused, equals: .key)
                    .accessibilityIdentifier("field.key")

                HStack(spacing: 10) {
                    Button {
                        Haptic.tap()
                        draft.privateKeyPEM = LaunchOptions.testCredentialSeed
                            ?? UIPasteboard.general.string
                            ?? ""
                    } label: {
                        Text("paste from clipboard")
                            .font(Mono.font(12))
                            .foregroundColor(Brand.claw)
                    }
                    // VoiceOver and UI automation need the result even when
                    // the summary below has scrolled just outside the
                    // visible part of the form.
                    .accessibilityValue(keySummary ?? "empty")
                    if let summary = keySummary {
                        Text(summary)
                            .font(Mono.font(11))
                            .foregroundColor(Brand.dim)
                    }
                }
            }
        }
    }

    /// Says what was pasted, so a wrong paste is obvious before a failed
    /// connection has to say it.
    private var keySummary: String? {
        let text = draft.privateKeyPEM
        guard !text.isEmpty else { return nil }
        guard text.contains("PRIVATE KEY") else { return "doesn’t look like a key" }
        return "key recognised"
    }

    private var keyPassphraseField: some View {
        labelled("KEY PASSPHRASE (IF ENCRYPTED)") {
            SecureField("", text: $draft.passphrase)
                .font(Mono.font(Metric.Field.textSize))
                .foregroundColor(Brand.text)
                .padding(.horizontal, Metric.Field.horizontalPadding)
                .frame(height: Metric.Field.height)
                .background(fieldBackground(focused: focused == .passphrase))
                .focused($focused, equals: .passphrase)
                .accessibilityIdentifier("field.passphrase")
        }
    }

    private var submit: some View {
        VStack(spacing: 8) {
            Button {
                Haptic.commit()
                onConnect(draft)
            } label: {
                Text("Connect")
                    .font(Mono.font(Metric.Submit.textSize, weight: .bold))
                    .foregroundColor(Brand.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metric.Submit.height)
                    .background(
                        Group {
                            if draft.isValid {
                                Brand.emberGradient
                            } else {
                                Color(red: 0x2E / 255, green: 0x25 / 255, blue: 0x1E / 255)
                            }
                        }
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: Metric.Submit.radius, style: .continuous)
                    )
            }
            .disabled(!draft.isValid)

            Text("will be saved to Recents")
                .font(Mono.font(12))
                .foregroundColor(Brand.dim)
        }
    }
}
