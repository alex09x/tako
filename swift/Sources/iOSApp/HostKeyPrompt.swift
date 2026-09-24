import SwiftUI

/// The one screen between typing a password and sending it somewhere.
///
/// A first connection shows the fingerprint and asks. A *changed* one does
/// not ask at all: it says so and offers no way through, because the two
/// explanations -- the host was rebuilt, or somebody is in the middle -- look
/// identical from here, and a phone at arm's length is the worst possible
/// place to guess between them.
struct HostKeyPrompt: View {
    let host: String
    let presented: KnownHosts.Presented
    let onTrust: () -> Void
    let onCancel: () -> Void
    @State private var actionsArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Capsule()
                    .fill(Brand.stroke)
                    .frame(width: Metric.Sheet.handleWidth, height: Metric.Sheet.handleHeight)
                Spacer()
            }
            .padding(.bottom, Metric.Sheet.handleGap)

            Text(presented.changed ? "Host key changed" : "Unknown host")
                .font(Mono.font(Metric.Sheet.titleSize, weight: .bold))
                .foregroundColor(presented.changed ? Brand.danger : Brand.paper)
                .padding(.bottom, 10)

            Text(presented.changed
                 ? "possible MITM — connection blocked"
                 : "\(host) is new. Its host key fingerprint:")
                .font(Mono.font(13))
                .foregroundColor(Brand.bodyMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text(presented.fingerprint)
                    .font(Mono.font(12))
                    .foregroundColor(presented.changed ? Brand.danger : Brand.claw)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(presented.algorithm)
                    .font(Mono.font(11))
                    .foregroundColor(Brand.dim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                    .fill(Brand.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metric.Field.radius, style: .continuous)
                            .stroke(presented.changed ? Brand.danger : Brand.stroke, lineWidth: 1)
                    )
            )

            Text(presented.changed
                 ? "if the host was rebuilt, drop it from known_hosts on your computer"
                 : "check against `ssh-keygen -lf` on the server · we’ll remember it")
                .font(Mono.font(11))
                .foregroundColor(Brand.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                if actionsArmed {
                    Button {
                        onCancel()
                    } label: {
                        cancelLabel
                    }
                    .id("armed-cancel")
                } else {
                    cancelLabel
                        .opacity(0.55)
                        .id("unarmed-cancel")
                }

                if !presented.changed {
                    if actionsArmed {
                        Button {
                            Haptic.commit()
                            onTrust()
                        } label: {
                            trustLabel
                        }
                        .id("armed-trust")
                    } else {
                        // A distinct noninteractive view, not a disabled
                        // Button: SwiftUI can carry the Connect gesture into
                        // a button that becomes enabled while it is pending.
                        trustLabel
                            .opacity(0.55)
                            .id("unarmed-trust")
                    }
                }
            }
        }
        .padding(.horizontal, Metric.Card.inset)
        .padding(.top, 10)
        .padding(.bottom, 30)
        .background(Brand.ink)
        .onAppear {
            if presented.changed { Haptic.warn() }
        }
        .task {
            // Both variants need a way out. A changed key deliberately has
            // no Trust action, but trapping the user in its sheet is not a
            // security feature. The delay still makes Cancel a second,
            // physically separate gesture from the Connect tap underneath.
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                actionsArmed = true
            } catch {
                // The prompt disappeared before it armed.
            }
        }
    }

    private var trustLabel: some View {
        Text("Trust")
            .font(Mono.font(Metric.Field.textSize, weight: .bold))
            .foregroundColor(Brand.paper)
            .frame(maxWidth: .infinity)
            .frame(height: Metric.Field.height)
            .background(Brand.emberGradient)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Metric.Sheet.itemRadius,
                    style: .continuous
                )
            )
    }

    private var cancelLabel: some View {
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

/// What the connect flow is doing, so the UI can say so instead of freezing.
enum ConnectPhase: Equatable {
    case idle
    /// Fetching the host key before anything secret is sent.
    case checking(String)
    case asking(String, KnownHosts.Presented)
    case failed(String)

    static func == (lhs: ConnectPhase, rhs: ConnectPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.checking(let a), .checking(let b)): return a == b
        case (.asking(let a, _), .asking(let b, _)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
