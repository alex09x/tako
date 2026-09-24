import SwiftUI

/// The first screen: every session as a card, and one way to make another.
struct SessionListScreen: View {
    @StateObject private var store = SessionStore()
    @State private var showingNewSession = false
    @State private var editingHost: SshDraft?
    @State private var openSession: Session?
    @State private var phase: ConnectPhase = .idle
    /// Held between the host-key prompt and the connection it gates.
    @State private var pending: SshDraft?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Brand.ink.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        wordmark
                            .padding(.leading, Metric.Wordmark.leadingInset)
                            .padding(.top, Metric.Wordmark.topInset)
                            .padding(.bottom, 20)

                        LazyVStack(spacing: Metric.Card.gap) {
                            ForEach(store.sessions) { session in
                                SessionCard(session: session) {
                                    resume(session)
                                }
                                .accessibilityIdentifier("session.\(session.title)")
                                .contextMenu {
                                    Button(session.needsCredentials ? "Connect" : "Reconnect") {
                                        resume(session)
                                    }
                                    Button("Delete", role: .destructive) { store.remove(session) }
                                }
                            }
                        }
                        .padding(.horizontal, Metric.Card.inset)

                        // Clears the pinned button so the last card is never
                        // hidden behind it.
                        Color.clear.frame(height: Metric.Submit.height + 40)
                    }
                }

                newSessionButton
                    .padding(.horizontal, Metric.Card.inset)
                    .padding(.bottom, Metric.Card.inset)
            }
            .navigationDestination(item: $openSession) { session in
                TerminalScreen(session: session)
            }
            .navigationDestination(item: $editingHost) { draft in
                SshFormScreen(draft: draft) { finished in
                    // The form deliberately stays up until the host key has
                    // been decided. Dismissing it here made iOS fire its own
                    // "Save Password?" prompt at exactly the moment the
                    // fingerprint sheet appeared -- so the system dialog
                    // covered the one thing the user is being asked to check
                    // before a password leaves the phone.
                    begin(finished)
                }
            }
            .overlay {
                if case .checking(let host) = phase {
                    checking(host)
                }
            }
            .sheet(isPresented: askingBinding) {
                if case .asking(let host, let presented) = phase, let draft = pending {
                    HostKeyPrompt(
                        host: host,
                        presented: presented,
                        onTrust: {
                            KnownHosts.trust(
                                host: draft.host,
                                port: UInt16(draft.port) ?? 22,
                                fingerprint: presented.fingerprint
                            )
                            phase = .idle
                            open(store.add(from: draft))
                        },
                        onCancel: {
                            phase = .idle
                            pending = nil
                            // The form is still the navigation destination
                            // underneath this sheet. Keep its entered host
                            // and credential choice available for inspection
                            // or correction instead of throwing the person
                            // back to the session list.
                        }
                    )
                    .presentationDetents([.height(420)])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(Brand.ink)
                }
            }
            .alert("Could not connect", isPresented: failedBinding) {
                Button("OK", role: .cancel) { phase = .idle; editingHost = nil }
            } message: {
                if case .failed(let why) = phase { Text(why) }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet(
                    recents: store.recents,
                    onLocal: {
                        showingNewSession = false
                        open(store.addLocal())
                    },
                    onNewHost: {
                        showingNewSession = false
                        editingHost = SshDraft()
                    },
                    onRecent: { draft in
                        showingNewSession = false
                        editingHost = draft
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Brand.ink)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: applyLaunchOptions)
    }

    /// Opening a card, whichever kind it is.
    ///
    /// A host restored from a previous launch has no key and no password --
    /// the app keeps where you went, never what got you in -- so it goes back
    /// through the form rather than to a terminal that would immediately fail
    /// authentication and say something unhelpful about it.
    private func resume(_ session: Session) {
        if session.needsCredentials, let draft = session.draft {
            editingHost = draft
        } else {
            if case .ssh = session.kind, case .disconnected = session.status {
                store.reconnect(session)
            }
            open(session)
        }
    }

    /// Puts the app where a script asked it to be. Does nothing at all
    /// without the arguments, so a shipped build never sees this path.
    private func applyLaunchOptions() {
        // SwiftUI may construct a StateObject during Simulator prewarming.
        // Reassert a requested clean trust store when the real scene becomes
        // visible, before any form can decide that a host is already known.
        if LaunchOptions.resetsState {
            KnownHosts.reset()
        }
        if let seed = LaunchOptions.testKnownHostSeed {
            KnownHosts.trust(
                host: seed.host,
                port: seed.port,
                fingerprint: seed.fingerprint
            )
        }
        if let draft = LaunchOptions.host {
            if LaunchOptions.trustsAnyHostKey {
                // A screenshot run cannot answer a prompt, so it says up
                // front that it will take whatever key it is given.
                pending = draft
                Task {
                    let outcome = await KnownHosts.probe(
                        host: draft.host,
                        port: UInt16(draft.port) ?? 22,
                        username: draft.username
                    )
                    if case .presented(let presented) = outcome {
                        KnownHosts.trust(
                            host: draft.host,
                            port: UInt16(draft.port) ?? 22,
                            fingerprint: presented.fingerprint
                        )
                    }
                    let session = store.add(from: draft)
                    open(session)
                    LaunchProbe.armIfAsked(session: session)
                }
            } else {
                editingHost = draft
            }
            return
        }

        switch LaunchOptions.screen {
        case .sheet: showingNewSession = true
        case .form: editingHost = SshDraft()
        case .terminal:
            if let first = store.sessions.first {
                open(first)
                LaunchProbe.armIfAsked(session: first)
            }
        case .none: break
        }
    }

    private var askingBinding: Binding<Bool> {
        Binding(
            get: { if case .asking = phase { return true }; return false },
            set: { if !$0 { phase = .idle } }
        )
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = phase { return true }; return false },
            set: { if !$0 { phase = .idle } }
        )
    }

    /// Looks at the host key before anything secret is sent. A host already
    /// trusted goes straight through only after the live key still matches;
    /// a new or changed one stops here.
    private func begin(_ draft: SshDraft) {
        pending = draft
        let port = UInt16(draft.port) ?? 22
        let trusted = KnownHosts.fingerprint(for: draft.host, port: port)

        phase = .checking(draft.host)
        Task {
            let outcome = await KnownHosts.probe(
                host: draft.host,
                port: port,
                username: draft.username
            )
            switch outcome {
            case .presented(let presented):
                if trusted != nil && !presented.changed {
                    // The probe saw the same key we remembered. Only now is
                    // it safe to start the authenticated connection and let
                    // its password or private key leave the phone.
                    phase = .idle
                    open(store.add(from: draft))
                    return
                }
                // A loopback probe can finish before the Connect gesture is
                // over. Never mount the security decision underneath that
                // still-live gesture: discovering and trusting a host must
                // require two physically separate actions.
                try? await Task.sleep(nanoseconds: 750_000_000)
                let endpoint = port == 22 ? draft.host : "\(draft.host):\(port)"
                phase = .asking(endpoint, presented)
            case .failed(let why):
                phase = .failed(why)
            }
        }
    }

    private func checking(_ host: String) -> some View {
        ZStack {
            Brand.scrim.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Brand.ember)
                Text("connecting to \(host)…")
                    .font(Mono.font(12))
                    .foregroundColor(Brand.bodyMuted)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: Metric.Card.radius, style: .continuous)
                    .fill(Brand.card)
            )
        }
    }

    private func open(_ session: Session) {
        Haptic.tap()
        editingHost = nil
        session.connect()
        openSession = session
    }

    /// Crab, then TAKO in paper and CORE in ember, on one line.
    private var wordmark: some View {
        HStack(spacing: 10) {
            CrabMark(size: Metric.Wordmark.markSize)
            (Text("TAKO").foregroundColor(Brand.paper)
                + Text("CORE").foregroundColor(Brand.ember))
                .font(Mono.font(Metric.Wordmark.textSize, weight: .heavy))
                .tracking(Metric.Wordmark.tracking)
        }
    }

    private var newSessionButton: some View {
        Button {
            Haptic.commit()
            showingNewSession = true
        } label: {
            HStack(spacing: 8) {
                Text("＋").font(Mono.font(16, weight: .bold))
                Text("new session").font(Mono.font(Metric.Submit.textSize, weight: .bold))
            }
            .foregroundColor(Brand.paper)
            .frame(maxWidth: .infinity)
            .frame(height: Metric.Submit.height)
            .background(Brand.emberGradient)
            .clipShape(RoundedRectangle(cornerRadius: Metric.Submit.radius, style: .continuous))
            .shadow(color: Brand.rust.opacity(0.35), radius: 10, x: 0, y: 8)
        }
        .accessibilityIdentifier("newSession")
    }
}

/// One session, as a card.
struct SessionCard: View {
    @ObservedObject var session: Session
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(session.statusColor)
                    .frame(width: Metric.Card.statusDot, height: Metric.Card.statusDot)

                VStack(alignment: .leading, spacing: Metric.Card.titleGap) {
                    Text(session.title)
                        .font(Mono.font(Metric.Card.titleSize))
                        .foregroundColor(Brand.paper)
                    Text(session.subtitle)
                        .font(Mono.font(Metric.Card.subtitleSize))
                        .foregroundColor(Brand.dim)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("›")
                    .font(Mono.font(16))
                    .foregroundColor(Brand.dim)
            }
            .padding(Metric.Card.padding)
            .background(Brand.card)
            .overlay(
                RoundedRectangle(cornerRadius: Metric.Card.radius, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metric.Card.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// The pixel crab, drawn from the brand grid rather than shipped as an asset
/// so it stays crisp at any size and needs no bundle plumbing.
struct CrabMark: View {
    let size: CGFloat

    /// 10 wide, 7 tall. 1 is the body, 2 the claws, 0 the background.
    private static let grid: [[Int]] = [
        [2, 0, 0, 0, 0, 0, 0, 0, 0, 2],
        [0, 2, 0, 1, 1, 1, 1, 0, 2, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 1, 0, 1, 1, 0, 1, 1, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 0, 1, 0, 0, 1, 0, 1, 0],
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let cols = Self.grid[0].count
            let rows = Self.grid.count
            let cell = min(canvasSize.width / CGFloat(cols), canvasSize.height / CGFloat(rows))
            let originX = (canvasSize.width - cell * CGFloat(cols)) / 2
            let originY = (canvasSize.height - cell * CGFloat(rows)) / 2

            for (row, line) in Self.grid.enumerated() {
                for (col, value) in line.enumerated() where value != 0 {
                    let rect = CGRect(
                        x: originX + CGFloat(col) * cell,
                        y: originY + CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(value == 2 ? Brand.claw : Brand.ember))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
