import Foundation

/// Pure per-axis scroll interpolation state (no I/O, injectable clock via the
/// caller). Holds the remaining pixel distance to emit and releases it with
/// an exponential decay, so consecutive wheel pulses accumulate momentum
/// instead of restarting an animation envelope.
///
/// Model: each `advance(dt:)` emits `amount * (1 - 0.5^(dt/halfLife))` and
/// reduces `amount` by the same value — output is conserved: the sum of all
/// emissions equals the sum of all feeds (within sub-pixel rounding carried
/// between frames). When the remainder drops below half a pixel it is
/// released in full so the axis always settles at exactly zero.
struct ScrollAxisSmoother {

    /// Time for ~87% of the remaining distance to be emitted (three
    /// half-lives). Derived from the user-facing duration setting.
    var halfLife: TimeInterval

    /// Pixels still owed to the app. Sign carries direction.
    private(set) var amount: Double = 0
    /// Sub-pixel remainder from the previous integer rounding, paid forward.
    private var carry: Double = 0

    init(duration: TimeInterval) {
        precondition(duration > 0, "duration must be positive")
        self.halfLife = max(duration / 3, 1.0 / 240.0)
    }

    /// Whether the axis has meaningful pending motion (drives the tick timer).
    var isActive: Bool { abs(amount) >= 0.5 }

    /// Add a wheel pulse (pixels, signed). Opposite-direction pulses subtract
    /// naturally, which reads as "braking then reversing" — like a trackpad.
    mutating func feed(_ delta: Double) {
        amount += delta
    }

    mutating func cancel() {
        amount = 0
        carry = 0
    }

    /// Emit the integer pixel distance for this frame. A large `dt` (e.g.
    /// after the run loop stalls) simply releases more of the remaining
    /// amount; nothing can blow up because output stays conserved.
    mutating func advance(dt: TimeInterval) -> Int {
        guard amount != 0 else { return 0 }
        let decay = pow(0.5, max(dt, 0) / halfLife)
        var release = amount * (1 - decay)
        amount -= release
        if abs(amount) < 0.5 {
            // Settle: pay out the sub-pixel tail so the axis reaches zero.
            release += amount
            amount = 0
        }
        let continuous = release + carry
        let whole: Double
        if amount == 0 {
            // Settling frame: round to nearest so the final sub-pixel carry
            // is paid out and the axis conserves distance exactly.
            whole = continuous.rounded()
            carry = 0
        } else {
            whole = continuous.rounded(.towardZero)
            carry = continuous - whole
        }
        return Int(whole)
    }
}

/// Both axes with independent interpolation state.
struct ScrollSmoother {

    private(set) var vertical: ScrollAxisSmoother
    private(set) var horizontal: ScrollAxisSmoother

    init(durationMS: Int) {
        let duration = TimeInterval(durationMS) / 1000
        self.vertical = ScrollAxisSmoother(duration: duration)
        self.horizontal = ScrollAxisSmoother(duration: duration)
    }

    /// Replace the easing duration; pending amounts survive.
    mutating func updateDuration(ms: Int) {
        let duration = TimeInterval(ms) / 1000
        vertical.halfLife = max(duration / 3, 1.0 / 240.0)
        horizontal.halfLife = max(duration / 3, 1.0 / 240.0)
    }

    var isActive: Bool { vertical.isActive || horizontal.isActive }

    mutating func feed(dy: Double, dx: Double) {
        if dy != 0 { vertical.feed(dy) }
        if dx != 0 { horizontal.feed(dx) }
    }

    mutating func cancel() {
        vertical.cancel()
        horizontal.cancel()
    }

    /// Integer pixels to post this frame; zeros mean the timer can idle.
    mutating func advance(dt: TimeInterval) -> (dy: Int, dx: Int) {
        (vertical.advance(dt: dt), horizontal.advance(dt: dt))
    }
}
