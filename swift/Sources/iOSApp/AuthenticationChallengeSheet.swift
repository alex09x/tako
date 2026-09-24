import SwiftUI

/// One keyboard-interactive request from the SSH server. It deliberately
/// contains prompt metadata but never the person's responses: answers live
/// only in the presented sheet and are released as soon as they are sent.
struct SSHAuthenticationChallenge: Identifiable, Equatable {
    struct Prompt: Identifiable, Equatable {
        let id: Int
        let text: String
        let echo: Bool
    }

    /// The Rust transport assigns a monotonically increasing value to each
    /// authentication round. Keeping it as the sheet identity prevents a
    /// late submission from one round being mistaken for the next one.
    let id: UInt64
    let name: String
    let instructions: String
    let prompts: [Prompt]
}

/// Native keyboard-interactive UI. Servers are allowed to send any number of
/// prompts (including zero), to mix hidden and echoed answers, and to issue a
/// second challenge after the first response. A new challenge identity gives
/// the next round fresh fields instead of retaining credentials from the
/// previous one.
struct AuthenticationChallengeSheet: View {
    private struct Answer: Identifiable {
        let id: Int
        let prompt: String
        let echo: Bool
        var response = ""
    }

    let challenge: SSHAuthenticationChallenge
    let onSubmit: ([String]) -> Void
    let onCancel: () -> Void

    @State private var answers: [Answer]
    @FocusState private var focusedAnswer: Int?

    init(
        challenge: SSHAuthenticationChallenge,
        onSubmit: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.challenge = challenge
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _answers = State(initialValue: challenge.prompts.map {
            Answer(id: $0.id, prompt: $0.text, echo: $0.echo)
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !challenge.instructions.isEmpty {
                        Text(challenge.instructions)
                            .font(.body)
                            .foregroundStyle(Brand.bodyMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("auth.challenge.instructions")
                    }

                    ForEach($answers) { $answer in
                        promptField(answer: $answer)
                    }

                    if answers.isEmpty {
                        Text("The server is waiting for confirmation.")
                            .font(.body)
                            .foregroundStyle(Brand.bodyMuted)
                    }
                }
                .padding(Metric.Card.inset)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.ink)
            .navigationTitle(challenge.name.isEmpty ? "Additional authentication" : challenge.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Brand.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        focusedAnswer = nil
                        onCancel()
                    }
                    .accessibilityIdentifier("auth.challenge.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    focusedAnswer = nil
                    onSubmit(answers.map(\.response))
                } label: {
                    Text("Continue")
                        .font(Mono.font(Metric.Submit.textSize, weight: .bold))
                        .foregroundStyle(Brand.paper)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metric.Submit.height)
                        .background(Brand.emberGradient)
                        .clipShape(.rect(cornerRadius: Metric.Submit.radius))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("auth.challenge.submit")
                .padding(.horizontal, Metric.Card.inset)
                .padding(.vertical, 10)
                .background(Brand.ink)
            }
        }
        // Swiping this away would strand the SSH runtime awaiting answers.
        // The explicit Cancel button sends a protocol cancellation instead.
        .interactiveDismissDisabled()
        .presentationBackground(Brand.ink)
    }

    @ViewBuilder
    private func promptField(answer: Binding<Answer>) -> some View {
        let fallback = "Response"
        let label = answer.wrappedValue.prompt.isEmpty
            ? fallback
            : answer.wrappedValue.prompt

        VStack(alignment: .leading, spacing: Metric.Field.labelGap) {
            Text(label)
                .font(Mono.font(Metric.Field.labelSize))
                .tracking(Metric.Field.labelTracking)
                .foregroundStyle(Brand.dim)

            Group {
                if answer.wrappedValue.echo {
                    TextField("", text: answer.response)
                } else {
                    SecureField("", text: answer.response)
                }
            }
            .font(Mono.font(Metric.Field.textSize))
            .foregroundStyle(Brand.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, Metric.Field.horizontalPadding)
            .frame(height: Metric.Field.height)
            .background(
                RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                    .fill(Brand.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                            .stroke(
                                focusedAnswer == answer.wrappedValue.id ? Brand.ember : Brand.stroke,
                                lineWidth: focusedAnswer == answer.wrappedValue.id ? 1.5 : 1
                            )
                    }
            )
            .focused($focusedAnswer, equals: answer.wrappedValue.id)
            .accessibilityLabel(label)
            .accessibilityIdentifier("auth.challenge.prompt.\(answer.wrappedValue.id)")
            .onSubmit { submitIfLast(answer.wrappedValue.id) }
        }
    }

    private func submitIfLast(_ id: Int) {
        guard answers.last?.id == id else {
            guard let current = answers.firstIndex(where: { $0.id == id }),
                  answers.indices.contains(current + 1) else { return }
            focusedAnswer = answers[current + 1].id
            return
        }
        focusedAnswer = nil
        onSubmit(answers.map(\.response))
    }
}
