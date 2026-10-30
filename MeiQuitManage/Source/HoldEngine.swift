import Foundation
import QuartzCore

/// Pure state machine for one "hold ⌘Q" session. UI and event plumbing live
/// elsewhere; this type only tracks time and reports progress.
final class HoldEngine {

    enum Phase: Equatable {
        case idle
        case holding
        /// The delay elapsed and the quit action has fired. Further updates
        /// are ignored until the session is reset.
        case fired
    }

    private(set) var phase: Phase = .idle
    private(set) var startTime: TimeInterval = 0

    /// Seconds of continuous holding required before quitting.
    let delay: TimeInterval

    /// Monotonic clock, injectable for tests.
    var now: () -> TimeInterval

    /// Fired exactly once, when the hold duration is reached.
    var onFired: (() -> Void)?

    init(delay: TimeInterval, now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        precondition(delay > 0, "delay must be positive")
        self.delay = delay
        self.now = now
    }

    /// Progress toward the quit threshold, in `0...1`.
    var fraction: Double {
        guard phase == .holding else { return phase == .fired ? 1 : 0 }
        return min(1, max(0, (now() - startTime) / delay))
    }

    /// Seconds elapsed since the hold began.
    var elapsed: TimeInterval {
        guard phase != .idle else { return 0 }
        return now() - startTime
    }

    /// Seconds remaining until the quit fires.
    var remaining: TimeInterval {
        guard phase == .holding else { return 0 }
        return max(0, delay - (now() - startTime))
    }

    /// Begin a hold. Returns `false` if a session is already in progress.
    @discardableResult
    func begin() -> Bool {
        guard phase == .idle else { return false }
        startTime = now()
        phase = .holding
        return true
    }

    /// Advance the state; called from a display-link style timer.
    func update() {
        guard phase == .holding else { return }
        if now() - startTime >= delay {
            phase = .fired
            onFired?()
        }
    }

    /// Abandon the session (user released ⌘Q too early).
    func cancel() {
        phase = .idle
    }
}
