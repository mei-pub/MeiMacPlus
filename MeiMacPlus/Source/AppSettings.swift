import Foundation
import Combine

/// User-facing settings, persisted in `UserDefaults`.
///
/// Key names intentionally mirror SlowQuitApps (`delay`, `whitelist`,
/// `invertList`, `displayOverlay`) so users migrating with
/// `defaults write com.dteoh.SlowQuitApps …` habits find the same vocabulary.
final class AppSettings: ObservableObject {

    enum Change {
        case enabled
        case delay
        case overlay
        case whitelist
        case invertList
        case keepAwake
        case scroll
        case script
    }

    static let shared = AppSettings()

    /// Injectable for unit tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            DefaultsKeys.enabled: true,
            DefaultsKeys.delay: 1000,
            DefaultsKeys.displayOverlay: true,
            DefaultsKeys.invertList: false,
            DefaultsKeys.whitelist: [String](),
            DefaultsKeys.keepAwakeOnLidClose: false,
            DefaultsKeys.scrollEnabled: false,
            DefaultsKeys.scrollSmoothEnabled: true,
            DefaultsKeys.scrollDurationMS: 300,
            DefaultsKeys.scrollGain: 1.0,
            DefaultsKeys.scrollReverseVertical: false,
            DefaultsKeys.scrollReverseHorizontal: false,
            DefaultsKeys.scrollBlacklist: [String](),
            DefaultsKeys.scriptEnabled: false,
        DefaultsKeys.scriptCustomPath: "",
        DefaultsKeys.spoonsEnabled: [String](),
        ])
        enabled = defaults.bool(forKey: DefaultsKeys.enabled)
        delayMilliseconds = defaults.integer(forKey: DefaultsKeys.delay)
        displayOverlay = defaults.bool(forKey: DefaultsKeys.displayOverlay)
        invertList = defaults.bool(forKey: DefaultsKeys.invertList)
        whitelist = defaults.stringArray(forKey: DefaultsKeys.whitelist) ?? []
        keepAwakeOnLidClose = defaults.bool(forKey: DefaultsKeys.keepAwakeOnLidClose)
        scrollEnabled = defaults.bool(forKey: DefaultsKeys.scrollEnabled)
        scrollSmoothEnabled = defaults.bool(forKey: DefaultsKeys.scrollSmoothEnabled)
        scrollDurationMS = defaults.integer(forKey: DefaultsKeys.scrollDurationMS)
        scrollGain = defaults.object(forKey: DefaultsKeys.scrollGain) as? Double ?? 1.0
        scrollReverseVertical = defaults.bool(forKey: DefaultsKeys.scrollReverseVertical)
        scrollReverseHorizontal = defaults.bool(forKey: DefaultsKeys.scrollReverseHorizontal)
        scrollBlacklist = defaults.stringArray(forKey: DefaultsKeys.scrollBlacklist) ?? []
        scriptEnabled = defaults.bool(forKey: DefaultsKeys.scriptEnabled)
        scriptCustomPath = defaults.string(forKey: DefaultsKeys.scriptCustomPath) ?? ""
        spoonsEnabled = Set(defaults.stringArray(forKey: DefaultsKeys.spoonsEnabled) ?? [])
    }

    /// Called on the main thread after any setting changes.
    var onChange: ((Change) -> Void)?

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: DefaultsKeys.enabled); onChange?(.enabled) }
    }

    /// Hold duration in milliseconds. Clamped to a sane range.
    @Published var delayMilliseconds: Int {
        didSet {
            let clamped = min(max(delayMilliseconds, Self.minDelayMs), Self.maxDelayMs)
            if clamped != delayMilliseconds { delayMilliseconds = clamped; return }
            defaults.set(delayMilliseconds, forKey: DefaultsKeys.delay)
            onChange?(.delay)
        }
    }

    @Published var displayOverlay: Bool {
        didSet { defaults.set(displayOverlay, forKey: DefaultsKeys.displayOverlay); onChange?(.overlay) }
    }

    @Published var invertList: Bool {
        didSet { defaults.set(invertList, forKey: DefaultsKeys.invertList); onChange?(.invertList) }
    }

    @Published var whitelist: [String] {
        didSet { defaults.set(whitelist, forKey: DefaultsKeys.whitelist); onChange?(.whitelist) }
    }

    /// "Keep awake with the lid closed" (`pmset disablesleep`). The stored
    /// value is synced from the real system state at launch; changing it goes
    /// through the privileged helper (see KeepAwakeManager).
    @Published var keepAwakeOnLidClose: Bool {
        didSet { defaults.set(keepAwakeOnLidClose, forKey: DefaultsKeys.keepAwakeOnLidClose); onChange?(.keepAwake) }
    }

    // MARK: - Mouse scroll enhancement

    /// Master switch for the scroll engine (tap install/uninstall).
    @Published var scrollEnabled: Bool {
        didSet { defaults.set(scrollEnabled, forKey: DefaultsKeys.scrollEnabled); onChange?(.scroll) }
    }

    /// Interpolate wheel events into continuous motion. When off, only the
    /// direction-reversal switches still act.
    @Published var scrollSmoothEnabled: Bool {
        didSet { defaults.set(scrollSmoothEnabled, forKey: DefaultsKeys.scrollSmoothEnabled); onChange?(.scroll) }
    }

    /// Easing duration in milliseconds. Clamped.
    @Published var scrollDurationMS: Int {
        didSet {
            let clamped = min(max(scrollDurationMS, Self.minScrollDurationMS), Self.maxScrollDurationMS)
            if clamped != scrollDurationMS { scrollDurationMS = clamped; return }
            defaults.set(scrollDurationMS, forKey: DefaultsKeys.scrollDurationMS)
            onChange?(.scroll)
        }
    }

    /// Distance multiplier per wheel pulse. Clamped.
    @Published var scrollGain: Double {
        didSet {
            let clamped = min(max(scrollGain, Self.minScrollGain), Self.maxScrollGain)
            if clamped != scrollGain { scrollGain = clamped; return }
            defaults.set(scrollGain, forKey: DefaultsKeys.scrollGain)
            onChange?(.scroll)
        }
    }

    /// Flip the vertical scroll direction of wheel mice only (trackpads and
    /// Magic Mouse are untouched).
    @Published var scrollReverseVertical: Bool {
        didSet { defaults.set(scrollReverseVertical, forKey: DefaultsKeys.scrollReverseVertical); onChange?(.scroll) }
    }

    @Published var scrollReverseHorizontal: Bool {
        didSet { defaults.set(scrollReverseHorizontal, forKey: DefaultsKeys.scrollReverseHorizontal); onChange?(.scroll) }
    }

    /// Bundle IDs that never get enhanced scrolling.
    @Published var scrollBlacklist: [String] {
        didSet { defaults.set(scrollBlacklist, forKey: DefaultsKeys.scrollBlacklist); onChange?(.scroll) }
    }

    // MARK: - Scripting

    /// Master switch for the embedded Lua (Hammerspoon) runtime.
    @Published var scriptEnabled: Bool {
        didSet { defaults.set(scriptEnabled, forKey: DefaultsKeys.scriptEnabled); onChange?(.script) }
    }

    /// User-chosen scripts directory. Empty = default resolution
    /// (~/.hammerspoon when present, else MeiMacPlus's own folder).
    @Published var scriptCustomPath: String {
        didSet { defaults.set(scriptCustomPath, forKey: DefaultsKeys.scriptCustomPath); onChange?(.script) }
    }

    /// Bundled Spoons that should be active (loaded after the runtime boots).
    /// All Spoons ship inside the app; nothing is enabled until the user
    /// flips its switch.
    @Published var spoonsEnabled: Set<String> {
        didSet { defaults.set(Array(spoonsEnabled).sorted(), forKey: DefaultsKeys.spoonsEnabled); onChange?(.script) }
    }

    var delaySeconds: TimeInterval { TimeInterval(delayMilliseconds) / 1000 }

    static let minDelayMs = 200
    static let maxDelayMs = 5000

    static let minScrollDurationMS = 100
    static let maxScrollDurationMS = 1000
    static let minScrollGain = 0.5
    static let maxScrollGain = 3.0

    private let defaults: UserDefaults
    private enum DefaultsKeys {
        static let enabled = "enabled"
        static let delay = "delay"
        static let displayOverlay = "displayOverlay"
        static let invertList = "invertList"
        static let whitelist = "whitelist"
        static let keepAwakeOnLidClose = "keepAwakeOnLidClose"
        static let scrollEnabled = "scrollEnabled"
        static let scrollSmoothEnabled = "scrollSmoothEnabled"
        static let scrollDurationMS = "scrollDurationMS"
        static let scrollGain = "scrollGain"
        static let scrollReverseVertical = "scrollReverseVertical"
        static let scrollReverseHorizontal = "scrollReverseHorizontal"
        static let scrollBlacklist = "scrollBlacklist"
        static let scriptEnabled = "scriptEnabled"
        static let scriptCustomPath = "scriptCustomPath"
        static let spoonsEnabled = "spoonsEnabled"
    }
}
