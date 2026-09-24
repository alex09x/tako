import QuartzCore

/// What a consumer reads to tell display cadence from encode throughput.
///
/// One value, not three properties: a sequence read separately from its
/// timestamp can be taken from frame N while the timestamp comes from N+1,
/// which is a gap measurement of a frame interval that never existed. The
/// three fields are only meaningful together, so they are only readable
/// together.
public struct TerminalPresentationCadence: Equatable, Sendable {
    /// Frames handed to the display, since this surface was made.
    ///
    /// Counted when a drawable-backed command buffer is committed for
    /// on-screen presentation, and only then. A frame that was planned but
    /// not renderable, or that found no drawable to draw into, or that was
    /// captured offscreen, never reached a display and is not counted here.
    ///
    /// Read against `sequence`, this is what separates a renderer that has
    /// stopped producing from a display that has stopped showing:
    ///
    ///   both advance          frames are being drawn and shown
    ///   submitted only        drawn, not shown -- below this surface
    ///   neither advances      nothing was drawn -- above it
    ///
    /// Strictly increasing; never reset by a renderer being rebuilt.
    public let submitted: UInt64

    /// Frames that actually reached the display, since this surface was made.
    /// Strictly increasing; never reset by a renderer being rebuilt.
    public let sequence: UInt64

    /// When the most recent frame reached the display, on the same monotonic
    /// clock as `CACurrentMediaTime`. Zero until the first present.
    public let presentedTime: CFTimeInterval

    /// Seconds between the two most recent presents. Zero until the second.
    ///
    /// Measured between the frames that were presented rather than between
    /// the moments a consumer happened to read, so a slow reader cannot
    /// flatter or slander the display.
    public let interval: CFTimeInterval

    public init(
        submitted: UInt64,
        sequence: UInt64,
        presentedTime: CFTimeInterval,
        interval: CFTimeInterval
    ) {
        self.submitted = submitted
        self.sequence = sequence
        self.presentedTime = presentedTime
        self.interval = interval
    }

    /// Nothing has been drawn or presented yet.
    public static let none = TerminalPresentationCadence(
        submitted: 0, sequence: 0, presentedTime: 0, interval: 0)
}

/// Presentation cadence for one terminal surface, across every renderer that
/// surface ever builds.
///
/// Lives on the view rather than on the renderer deliberately. A theme, font
/// or backing-scale change tears the renderer down and builds another; a
/// counter that lived there would restart at zero, and to a consumer watching
/// for stalls a sequence that stops advancing is indistinguishable from the
/// display having stopped. The surface outlives its renderers, so the count
/// does too.
///
/// Written from Metal's presented handler, which is not the main thread, and
/// read from wherever a consumer asks. Every access takes the lock.
public final class TerminalPresentationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var state = TerminalPresentationCadence.none

    public init() {}

    /// One coherent read: all three fields from the same presented frame.
    public var cadence: TerminalPresentationCadence {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Record a frame that reached the display.
    ///
    /// Deliberately not public. This value is evidence of what a display
    /// actually did, and a consumer that could advance it could forge that
    /// evidence -- including permanently, since the ordering rule below would
    /// then reject every real presentation behind the forged one. Only this
    /// module, from Metal's presented handler, may write here; everyone else
    /// reads `cadence`.
    ///
    /// Only a real, strictly later presentation advances anything. A drawable
    /// that was never shown reports zero; a handler that fires twice for one
    /// frame, or out of order behind another, would otherwise invent presents
    /// that did not happen or a negative interval. A non-finite timestamp is
    /// refused for the same reason: an infinity here would sit above every
    /// real presentation forever.
    func record(presentedAt time: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard time.isFinite, time > 0, time > state.presentedTime else { return }
        let interval = state.presentedTime > 0 ? time - state.presentedTime : 0
        state = TerminalPresentationCadence(
            submitted: state.submitted,
            sequence: state.sequence &+ 1,
            presentedTime: time,
            interval: interval
        )
    }

    /// Record a frame handed to the display.
    ///
    /// Called once a drawable-backed command buffer has been committed for
    /// on-screen presentation -- the last moment this side controls. It is
    /// deliberately not called for a frame that was rejected before drawing,
    /// found no drawable, or was captured offscreen: none of those were ever
    /// on their way to a display, and counting them would turn the pair into
    /// two ways of measuring the same thing.
    ///
    /// Internal for the same reason as `record`: a consumer that could
    /// advance this could claim work that was never done.
    func recordSubmitted() {
        lock.lock()
        defer { lock.unlock() }
        state = TerminalPresentationCadence(
            submitted: state.submitted &+ 1,
            sequence: state.sequence,
            presentedTime: state.presentedTime,
            interval: state.interval
        )
    }
}
