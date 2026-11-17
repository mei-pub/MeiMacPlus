import Foundation

/// Immutable snapshot of the user's scroll-enhancement settings. Built on the
/// main thread, stored behind a lock in `ScrollEngine`, read on the tap
/// thread — never read `AppSettings` (a main-actor object) from the tap.
struct ScrollConfig: Equatable {
    var enabled = false
    var smoothEnabled = true
    /// Easing duration in milliseconds (see `ScrollSmoother`).
    var durationMS = 300
    /// Distance multiplier per wheel pulse.
    var gain = 1.0
    var reverseVertical = false
    var reverseHorizontal = false
    var blacklist: Set<String> = []

    static func from(_ settings: AppSettings) -> ScrollConfig {
        var config = ScrollConfig()
        config.enabled = settings.scrollEnabled
        config.smoothEnabled = settings.scrollSmoothEnabled
        config.durationMS = settings.scrollDurationMS
        config.gain = settings.scrollGain
        config.reverseVertical = settings.scrollReverseVertical
        config.reverseHorizontal = settings.scrollReverseHorizontal
        config.blacklist = Set(settings.scrollBlacklist)
        return config
    }
}

/// Pure decision logic: given an incoming scroll event's traits and the
/// current config, decide what the engine does with it.
enum ScrollPolicy {

    enum Decision: Equatable {
        /// Leave the event untouched.
        case passthrough
        /// Flip delta signs on the event in place and let it through
        /// (reverse enabled, smoothing off).
        case reverseInPlace
        /// Swallow the event and hand its distance to the interpolator.
        case smooth
    }

    static func decide(
        config: ScrollConfig,
        isContinuous: Bool,
        isFromSelf: Bool,
        frontmostBundleID: String?
    ) -> Decision {
        guard config.enabled else { return .passthrough }
        // Events we synthesized ourselves must never be re-processed.
        guard !isFromSelf else { return .passthrough }
        // Trackpads and Magic Mouse scroll with continuous events; leave
        // them alone — the whole point is to fix wheel-mouse stepping.
        guard !isContinuous else { return .passthrough }
        if let id = frontmostBundleID, config.blacklist.contains(id) {
            return .passthrough
        }
        if config.smoothEnabled {
            return .smooth
        }
        if config.reverseVertical || config.reverseHorizontal {
            return .reverseInPlace
        }
        return .passthrough
    }
}
