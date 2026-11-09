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
        ])
        enabled = defaults.bool(forKey: DefaultsKeys.enabled)
        delayMilliseconds = defaults.integer(forKey: DefaultsKeys.delay)
        displayOverlay = defaults.bool(forKey: DefaultsKeys.displayOverlay)
        invertList = defaults.bool(forKey: DefaultsKeys.invertList)
        whitelist = defaults.stringArray(forKey: DefaultsKeys.whitelist) ?? []
        keepAwakeOnLidClose = defaults.bool(forKey: DefaultsKeys.keepAwakeOnLidClose)
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

    var delaySeconds: TimeInterval { TimeInterval(delayMilliseconds) / 1000 }

    static let minDelayMs = 200
    static let maxDelayMs = 5000

    private let defaults: UserDefaults
    private enum DefaultsKeys {
        static let enabled = "enabled"
        static let delay = "delay"
        static let displayOverlay = "displayOverlay"
        static let invertList = "invertList"
        static let whitelist = "whitelist"
        static let keepAwakeOnLidClose = "keepAwakeOnLidClose"
    }
}
