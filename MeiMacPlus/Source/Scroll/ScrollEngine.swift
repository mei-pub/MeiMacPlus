import AppKit
import CoreGraphics
import ApplicationServices
import Foundation
import os

let scrollLog = Logger(subsystem: "com.meimacplus.MeiMacPlus", category: "scroll")

/// Mouse-wheel enhancement pipeline: a scroll-wheel event tap, an easing
/// interpolator, and a synthetic-event poster, all owned by one dedicated
/// thread so the tap callback and the tick timer run sequentially without
/// locks between them.
///
/// Threading contract:
/// - `start`, `stop`, `updateConfig` and `monitor` are called from the main
///   thread only.
/// - The tap callback, tick timer and poster run on the engine thread.
/// - Shared state crossing the boundary (`ScrollConfig`, frontmost bundle ID)
///   goes through small lock-guarded boxes.
///
/// Loop-back protection is two-fold: synthetic events are posted through a
/// private event source whose state ID is checked in the callback, and they
/// are marked continuous, which the policy passes through anyway (as it must
/// for real trackpad events).
final class ScrollEngine {

    /// Tick rate for the interpolation driver, ~1.4 display frames.
    private static let tickInterval: TimeInterval = 1.0 / 90.0
    /// Fallback pixels per wheel line when an event carries no pixel delta.
    private static let pixelsPerLine: Double = 10.0

    let monitor = ScrollMonitorStore()

    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var startupResult = DispatchSemaphore(value: 0)

    private let configBox = LockedValue<ScrollConfig>(ScrollConfig())
    private let frontmostBox = LockedValue<String?>(nil)
    private var frontmostObserver: NSObjectProtocol?

    /// Engine-thread state.
    private var tap: CFMachPort?
    private var driverTimer: Timer?
    private var smoother = ScrollSmoother(durationMS: ScrollConfig().durationMS)
    private var lastTickAt: TimeInterval = 0
    private var posterSource: CGEventSource?

    init() {
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBox.write(app?.bundleIdentifier)
        }
        frontmostBox.write(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    deinit {
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
        }
    }

    // MARK: - Main-thread API

    /// Publish new settings to the tap thread. The engine keeps running;
    /// whether it runs at all is decided by `start`/`stop`.
    func updateConfig(_ config: ScrollConfig) {
        configBox.write(config)
    }

    /// Spin up the engine thread. Returns `false` when accessibility trust is
    /// missing or the tap could not be created.
    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }
        guard AXIsProcessTrusted() else {
            scrollLog.error("start aborted: not trusted for accessibility")
            return false
        }

        let done = DispatchSemaphore(value: 0)
        startupResult = done
        let t = Thread(block: { [weak self] in
            self?.threadMain()
        })
        t.name = "com.meimacplus.scroll-engine"
        t.start()
        thread = t

        guard done.wait(timeout: .now() + 2) == .success, threadRunLoop != nil else {
            scrollLog.error("engine thread failed to arm the event tap")
            stop()
            return false
        }
        scrollLog.notice("scroll engine started")
        return true
    }

    func stop() {
        guard thread != nil else { return }
        thread = nil
        if let runLoop = threadRunLoop {
            CFRunLoopStop(runLoop)
        }
        threadRunLoop = nil
        // The thread invalidates the tap and timer on its way out; the
        // run loop is already drained of our sources, so no join is needed.
        scrollLog.notice("scroll engine stopped")
    }

    // MARK: - Engine thread

    private func threadMain() {
        let runLoop = CFRunLoopGetCurrent()

        let mask = 1 << CGEventType.scrollWheel.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            scrollLog.error("CGEvent.tapCreate returned nil on the engine thread")
            threadRunLoop = runLoop
            startupResult.signal()
            return
        }
        tap = eventTap

        // A private event-source state keeps our synthesized events from
        // perturbing the shared HID state; recognition uses the user-data
        // marker (see `isFromOurs`) since events don't expose their source.
        posterSource = CGEventSource(stateID: Self.privateStateID)

        let tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let tapSource {
            CFRunLoopAddSource(runLoop, tapSource, .defaultMode)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        threadRunLoop = runLoop
        startupResult.signal()

        CFRunLoopRun()

        // Teardown (after stop() or tap-creation failure bail-out above).
        if let tapSource {
            CFRunLoopRemoveSource(runLoop, tapSource, .defaultMode)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        driverTimer?.invalidate()
        driverTimer = nil
        posterSource = nil
    }

    /// A private (unregistered) event-source state: every `CGEventSource`
    /// created with it gets its own isolated HID state.
    private static let privateStateID: CGEventSourceStateID = CGEventSourceStateID(
        rawValue: -1 // kCGEventSourceStatePrivate; always valid
    )!

    // MARK: Tap callback (engine thread)

    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            scrollLog.error("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)

        case .scrollWheel:
            break

        default:
            return Unmanaged.passRetained(event)
        }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1
        let isFromSelf = isFromOurs(event)

        let config = configBox.read()
        let frontmost = frontmostBox.read()
        let decision = ScrollPolicy.decide(
            config: config,
            isContinuous: isContinuous,
            isFromSelf: isFromSelf,
            frontmostBundleID: frontmost
        )

        let source: ScrollMonitorStore.Record.Source =
            isFromSelf ? .synthetic : (isContinuous ? .trackpad : .mouse)

        switch decision {
        case .passthrough:
            if !isFromSelf {
                monitor.append(.init(
                    timestamp: CACurrentMediaTime(),
                    source: source,
                    dy: eventPointDelta(event, axis: 1),
                    dx: eventPointDelta(event, axis: 2),
                    decision: "pass",
                    app: frontmost
                ))
            }
            return Unmanaged.passRetained(event)

        case .reverseInPlace:
            monitor.append(.init(
                timestamp: CACurrentMediaTime(),
                source: source,
                dy: eventPointDelta(event, axis: 1),
                dx: eventPointDelta(event, axis: 2),
                decision: "reverse",
                app: frontmost
            ))
            if config.reverseVertical { flipAxis(event, axis: 1) }
            if config.reverseHorizontal { flipAxis(event, axis: 2) }
            return Unmanaged.passRetained(event)

        case .smooth:
            let dyLine = eventLineDelta(event, axis: 1)
            let dxLine = eventLineDelta(event, axis: 2)
            let rawDY = Double(eventPointDelta(event, axis: 1) ?? Int(dyLine * Int32(Self.pixelsPerLine)))
            let rawDX = Double(eventPointDelta(event, axis: 2) ?? Int(dxLine * Int32(Self.pixelsPerLine)))
            guard rawDY != 0 || rawDX != 0 else { return nil }

            var dy = rawDY * config.gain
            var dx = rawDX * config.gain
            if config.reverseVertical { dy = -dy }
            if config.reverseHorizontal { dx = -dx }

            monitor.append(.init(
                timestamp: CACurrentMediaTime(),
                source: source,
                dy: Int(rawDY),
                dx: Int(rawDX),
                decision: "smooth",
                app: frontmost
            ))

            smoother.updateDuration(ms: config.durationMS)
            smoother.feed(dy: dy, dx: dx)
            ensureDriverRunning()
            return nil // swallow the original stepped event
        }
    }

    /// Marker stamped on synthesized events (`kCGEventSourceUserData`);
    /// real hardware events carry 0 there.
    private static let syntheticMarker: Int64 = 0x4D50_5352 // "MPSR"

    private func isFromOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
    }

    private func eventPointDelta(_ event: CGEvent, axis: Int32) -> Int? {
        let field: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let value = Int(event.getIntegerValueField(field))
        return value == 0 ? nil : value
    }

    private func eventLineDelta(_ event: CGEvent, axis: Int32) -> Int32 {
        let field: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        return Int32(event.getIntegerValueField(field))
    }

    /// Flip every representation of one axis so all apps (which read
    /// different fields) agree on the new direction.
    private func flipAxis(_ event: CGEvent, axis: Int32) {
        let delta: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let point: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixed: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        event.setIntegerValueField(delta, value: -event.getIntegerValueField(delta))
        event.setIntegerValueField(point, value: -event.getIntegerValueField(point))
        event.setIntegerValueField(fixed, value: -event.getIntegerValueField(fixed))
    }

    // MARK: Interpolation driver (engine thread)

    private func ensureDriverRunning() {
        guard driverTimer == nil else { return }
        lastTickAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        let runLoop = RunLoop.current
        runLoop.add(timer, forMode: .default)
        driverTimer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTickAt
        lastTickAt = now

        let (dy, dx) = smoother.advance(dt: dt)
        if dy != 0 || dx != 0 {
            postSynthetic(dy: dy, dx: dx)
            monitor.append(.init(
                timestamp: now,
                source: .synthetic,
                dy: dy,
                dx: dx,
                decision: "emit",
                app: frontmostBox.read()
            ))
        }
        if !smoother.isActive {
            driverTimer?.invalidate()
            driverTimer = nil
        }
    }

    private func postSynthetic(dy: Int, dx: Int) {
        guard let source = posterSource else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else { return }
        // Continuous + pixel deltas: apps treat it like a trackpad stream.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Loop-back guard: mark the event as ours for the tap callback.
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cgSessionEventTap)
    }
}

/// The C-convention callback cannot capture context; `userInfo` carries self.
private func scrollTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let engine = Unmanaged<ScrollEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.process(type, event)
}

/// Minimal lock-guarded box for cross-thread snapshots.
final class LockedValue<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
