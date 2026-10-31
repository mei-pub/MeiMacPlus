import AppKit
import CoreGraphics
import ApplicationServices
import os
import QuartzCore

let interceptorLog = Logger(subsystem: "com.meiquit.MeiQuitManage", category: "intercept")

/// Receives the high-level events of the interception lifecycle.
/// The tap source runs on the main run loop, so all requirements are
/// called on the main thread.
@MainActor
protocol CmdQInterceptorDelegate: AnyObject {
    /// Called on ⌘Q key-down (non-repeat). The delegate decides whether this
    /// press should start a hold session. Runs on the main thread.
    func interceptorRequestsIntercept(frontmostBundleID: String?) -> Bool
    /// A hold session began (fresh, non-repeat key-down accepted).
    func interceptorDidBeginHold()
    /// The Q key was released while we were swallowing events.
    func interceptorDidReceiveKeyUp()
    /// The Command modifier was released while we were swallowing events.
    func interceptorCommandWasReleased()
}

/// Global ⌘Q interception via a session event tap.
///
/// This requires the app to be non-sandboxed and trusted in
/// System Settings → Privacy & Security → Accessibility.
final class CmdQInterceptor {

    static let keyCodeQ: CGKeyCode = 12 // kVK_ANSI_Q

    weak var delegate: CmdQInterceptorDelegate?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// True between an accepted key-down and the matching key-up;
    /// all Q events in this window are swallowed (including auto-repeats).
    private var swallowing = false
    /// When the current swallow window opened; used to self-heal a window
    /// left open by a lost key-up event.
    private var swallowingSince: TimeInterval = 0
    /// Set when a session began while polling confirmed the physical key
    /// state API works; `nil` means "cannot be trusted" for the safety net.
    private var keyStateCalibrated: Bool?

    /// Whether the Q key is physically down right now, if that can be
    /// determined reliably. Used as a safety net in case the key-up event
    /// is ever lost (tap disabled mid-session, Secure Input, …).
    func qKeyIsPhysicallyDown() -> Bool? {
        guard keyStateCalibrated == true else { return nil }
        return CGEventSource.keyState(.combinedSessionState, key: Self.keyCodeQ)
    }

    /// Release the swallow window out-of-band (key state proves Q is up, so
    /// no key-up can arrive to do it).
    func forceResetSwallowing(reason: String) {
        if swallowing {
            interceptorLog.notice("force reset swallow window: \(reason, privacy: .public)")
            swallowing = false
        }
    }

    deinit {
        stop()
    }

    /// - Returns: `false` when accessibility trust is missing or the tap
    ///   could not be created.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.isProcessTrusted() else {
            interceptorLog.error("start aborted: not trusted for accessibility")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: interceptorTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            interceptorLog.error("start aborted: CGEvent.tapCreate returned nil")
            return false
        }
        interceptorLog.notice("event tap created")

        tap = eventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        swallowing = false
        isRunning = false
    }

    static func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Event processing (main run loop thread)

    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // Slow callback responses can disable the tap; revive it.
            interceptorLog.error("tap disabled by timeout — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)

        case .tapDisabledByUserInput:
            // E.g. Secure Input toggled; try to revive so the session end is still observed.
            interceptorLog.error("tap disabled by user input — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)

        case .flagsChanged:
            let commandDown = event.flags.contains(.maskCommand)
            // The delegate cancels the hold, but we keep swallowing Q events
            // until the actual key-up, so stray "q" characters never leak
            // into the frontmost app when Command is released first.
            if !commandDown && swallowing {
                interceptorLog.notice("command released during hold — cancel session")
                MainActor.assumeIsolated {
                    self.delegate?.interceptorCommandWasReleased()
                }
            }
            return Unmanaged.passRetained(event)

        case .keyDown, .keyUp:
            let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == Self.keyCodeQ else { return Unmanaged.passRetained(event) }

            if type == .keyDown {
                // Swallow repeats (and any stray key-downs) while a session is
                // active — including plain "q" repeats after Command was
                // released early. A window left open by a lost key-up self-heals.
                if swallowing {
                    if CACurrentMediaTime() - swallowingSince > 5 {
                        interceptorLog.error("stale swallow window (\(self.swallowingSince, privacy: .public)) — self-healing")
                        swallowing = false
                    } else {
                        return nil
                    }
                }
                guard event.flags.contains(.maskCommand) else {
                    return Unmanaged.passRetained(event) // plain "q" — none of our business
                }
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let shouldIntercept = MainActor.assumeIsolated {
                    self.delegate?.interceptorRequestsIntercept(frontmostBundleID: frontmost) ?? false
                }
                if shouldIntercept {
                    swallowing = true
                    swallowingSince = CACurrentMediaTime()
                    // Calibrate physical key-state polling: at this instant the
                    // Q key is definitely down, so a `false` here means the API
                    // is unreliable and the safety net must stay out of the way.
                    keyStateCalibrated = CGEventSource.keyState(.combinedSessionState, key: keyCode)
                    interceptorLog.notice("intercept ⌘Q (frontmost: \(frontmost ?? "nil", privacy: .public), keyStateCalibrated: \(self.keyStateCalibrated == true))")
                    MainActor.assumeIsolated {
                        self.delegate?.interceptorDidBeginHold()
                    }
                    return nil
                }
                interceptorLog.notice("pass through ⌘Q (frontmost: \(frontmost ?? "nil", privacy: .public))")
                return Unmanaged.passRetained(event)
            } else {
                if swallowing {
                    swallowing = false
                    interceptorLog.notice("key up — release swallow window")
                    MainActor.assumeIsolated {
                        self.delegate?.interceptorDidReceiveKeyUp()
                    }
                    return nil
                }
                return Unmanaged.passRetained(event)
            }

        default:
            return Unmanaged.passRetained(event)
        }
    }
}

/// The C-convention callback cannot capture context; `userInfo` carries self.
private func interceptorTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let interceptor = Unmanaged<CmdQInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return interceptor.process(type, event)
}
