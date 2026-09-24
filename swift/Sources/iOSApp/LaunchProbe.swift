import UIKit

/// Types into a session and writes what came back into the app's own
/// Documents directory.
///
/// A phone cannot be tapped or screenshotted from a script: `devicectl` has
/// neither verb, and the simulator's `simctl io screenshot` has no device
/// equivalent. So the only way to learn what the terminal actually drew on
/// the hardware is to have the app say so and pull the answer back out of its
/// container with `devicectl device copy from`.
///
/// Armed only by `-takoDump`, so a build launched by tapping it never runs
/// any of this.
@MainActor
enum LaunchProbe {
    static func armIfAsked(session: Session) {
        guard let deadline = LaunchOptions.dumpAfter else { return }
        waitForConnection(session: session, giveUpAfter: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            MainActor.assumeIsolated { write(session: session) }
        }
    }

    /// How long a `\p` waits. Long enough for a command to have produced its
    /// output before the next step assumes it did.
    ///
    /// Not private: unit tests read it to size their own waits rather than
    /// duplicating the constant.
    static let stepPause: TimeInterval = 1.5

    /// How long the far end must stay silent before scripted typing starts.
    static let promptQuiet: TimeInterval = 0.5

    /// Sends `-takoSend` once the far end is actually there and its shell has
    /// finished drawing: connected, mounted, has sent something, and has then
    /// been quiet for ``promptQuiet``. Typing into a shell that is still
    /// starting loses keystrokes -- fish 3.7 repaints over typeahead and drops
    /// the Enter -- which is not what a person at the keyboard ever does. A
    /// fixed delay would be either too short or a guess about how slow the
    /// network is, and both fail as a flake rather than as a message.
    /// Not private: unit tests call this directly, with their own
    /// `giveUpAfter`, instead of going through `armIfAsked` and its
    /// `-takoDump` deadline.
    static func waitForConnection(session: Session, giveUpAfter: TimeInterval) {
        let steps = LaunchOptions.sendSteps
        guard !steps.isEmpty else { return }
        let started = Date()

        func poll() {
            if session.status == .connected, session.surface != nil,
               let last = session.lastReceivedAt,
               Date().timeIntervalSince(last) >= promptQuiet {
                send(steps[...], to: session)
                return
            }
            guard Date().timeIntervalSince(started) < giveUpAfter else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
    }

    /// `-takoKeys` names, in the row's own glyphs. Spelled out because an
    /// argument list carrying `⌃` is a thing that survives one copy and paste
    /// and not two.
    private static let namedKeys: [String: String] = [
        "esc": "esc",
        "ctrl": KeyRow.control,
        "tab": KeyRow.tab,
        "up": KeyRow.up,
        "down": KeyRow.down,
        "dash": "-",
        "pipe": "|",
    ]

    /// Not private: unit tests exercise step pacing and delivery directly.
    static func send(_ steps: ArraySlice<String>, to session: Session) {
        guard let step = steps.first else { return }
        deliver(step, to: session)
        let rest = steps.dropFirst()
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + stepPause) {
            MainActor.assumeIsolated { send(rest, to: session) }
        }
    }

    /// A step is either text typed on the keyboard or a key-row press.
    ///
    /// Typed text goes through `insertText`, which is the method the software
    /// keyboard calls, and a press goes through ``KeyRow`` -- so what this
    /// exercises is the app's own input path rather than a shortcut past it
    /// that would pass while the real one was broken.
    /// Not private: unit tests deliver one step at a time to check the
    /// keyboard and key-row paths independently of the step scheduler.
    static func deliver(_ step: String, to session: Session) {
        guard step.hasPrefix("@") else {
            if let surface = session.surface {
                // One character per call, as the software keyboard delivers
                // them. A multi-character insertText is a paste: it goes out
                // bracketed, and a shell inserts a pasted newline into the
                // line instead of running it.
                for character in step {
                    surface.insertText(String(character))
                }
            } else {
                session.sendInput(Data(step.utf8))
            }
            return
        }
        for name in step.dropFirst().split(separator: "+") {
            let key = namedKeys[String(name)] ?? String(name)
            if let bytes = session.keyRow.bytes(for: key) {
                session.sendInput(Data(bytes))
            }
        }
    }

    /// Not private: unit tests call this directly rather than waiting out a
    /// real `-takoDump` deadline.
    static func write(session: Session) {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }

        // The screen the engine holds, rejoined across soft wraps. This is
        // the authoritative half: it says what the parser made of the bytes
        // the far end sent, independently of whether anything was drawn.
        let text = session.surface?.bufferText ?? "<no surface>"
        // The live screen as well as the whole buffer. They differ when
        // something is in the scrollback but not in front of the user, which
        // is the difference between "the app lost it" and "the app is not
        // showing it" -- and only one of those is a data bug.
        let onScreen = session.surface?.accessibilityValue ?? "<no surface>"
        let report = """
            status: \(session.status.label)
            title: \(session.title)
            ── on screen ──
            \(onScreen)
            ── buffer ──
            \(text)
            """
        try? report.write(to: docs.appendingPathComponent("dump.txt"),
                          atomically: true, encoding: .utf8)

        // And the pixels, for the half that a text dump cannot show: fonts,
        // colours, the key row, whether the Metal layer produced a frame at
        // all. `drawHierarchy` re-renders through the window server, which
        // is what makes it capture a CAMetalLayer -- `layer.render(in:)`
        // would hand back a hole where the terminal is.
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let png = renderer.pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: docs.appendingPathComponent("dump.png"))
    }
}
