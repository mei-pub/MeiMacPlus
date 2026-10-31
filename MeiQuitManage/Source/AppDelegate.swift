import AppKit
import os

let sessionLog = Logger(subsystem: "com.meiquit.MeiQuitManage", category: "session")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings.shared
    private let interceptor = CmdQInterceptor()
    private let overlay = OverlayWindowController()
    private let menuBar = MenuBarController()

    private var permissionGuide: PermissionGuideWindowController?
    private var settingsWindow: SettingsWindowController?

    /// Active hold session, if any.
    private var engine: HoldEngine?
    private var ticker: Timer?
    private var targetApp: NSRunningApplication?
    private var trustWatchdog: Timer?
    private var lastKnownTrusted: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else {
            NSApp.terminate(nil)
            return
        }

        wireMenuBar()
        interceptor.delegate = self
        settings.onChange = { [weak self] change in
            self?.settingsDidChange(change)
        }

        let trusted = CmdQInterceptor.isProcessTrusted()
        lastKnownTrusted = trusted
        if !trusted {
            sessionLog.error("launch: NOT trusted for accessibility — showing guide")
            showPermissionGuide()
        } else {
            sessionLog.notice("launch: trusted for accessibility")
            activateInterceptionIfDesired()
        }

        // Watchdog: the user may grant (or revoke) accessibility at any time,
        // including after closing the guide window. Pick up trust changes
        // automatically instead of requiring a relaunch or menu toggle.
        let watchdog = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trustDidChange()
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        trustWatchdog = watchdog
        sessionLog.notice("trust watchdog armed")
    }

    private func trustDidChange() {
        let trusted = CmdQInterceptor.isProcessTrusted()
        guard trusted != lastKnownTrusted else { return }
        lastKnownTrusted = trusted
        sessionLog.notice("trust state changed: \(trusted, privacy: .public)")
        menuBar.refresh()
        if trusted {
            activateInterceptionIfDesired()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustWatchdog?.invalidate()
        interceptor.stop()
        endSession(cancel: true)
    }

    // MARK: - Single instance

    private func ensureSingleInstance() -> Bool {
        // The unit-test host must not terminate itself when the app is
        // already running.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return true
        }
        guard let myID = Bundle.main.bundleIdentifier else { return true }
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == myID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            NSLog("MeiQuitManage is already running (pid \(existing.processIdentifier)); activating it.")
            existing.activate()
            return false
        }
        return true
    }

    // MARK: - Wiring

    private func wireMenuBar() {
        menuBar.install(owner: self)
        menuBar.onToggleEnabled = { [weak self] in
            guard let self else { return }
            self.settings.enabled.toggle()
        }
        menuBar.onSetDelay = { [weak self] ms in
            self?.settings.delayMilliseconds = ms
        }
        menuBar.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        menuBar.onToggleLoginItem = { [weak self] in
            guard let self else { return }
            let target = !LoginItemManager.isEnabled
            if !LoginItemManager.setEnabled(target) {
                NSLog("MeiQuitManage: failed to toggle launch-at-login")
            }
            self.menuBar.refresh()
        }
        menuBar.onOpenAbout = { [weak self] in
            self?.showAbout()
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }
        menuBar.refresh()
    }

    private func settingsDidChange(_ change: AppSettings.Change) {
        menuBar.refresh()
        switch change {
        case .enabled:
            activateInterceptionIfDesired()
        default:
            break
        }
    }

    private func activateInterceptionIfDesired() {
        guard settings.enabled else {
            if interceptor.isRunning {
                sessionLog.notice("protection paused — stopping tap")
                interceptor.stop()
            }
            return
        }
        guard CmdQInterceptor.isProcessTrusted() else { return }
        if !interceptor.isRunning {
            if !interceptor.start() {
                sessionLog.error("failed to start interception")
            }
        }
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.present()
    }

    func showPermissionGuide() {
        if permissionGuide == nil {
            let guide = PermissionGuideWindowController()
            guide.onPermissionGranted = { [weak self] in
                self?.menuBar.refresh()
                self?.activateInterceptionIfDesired()
            }
            permissionGuide = guide
        }
        permissionGuide?.present()
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(
            options: [
                .applicationVersion: L(
                    "about.version",
                    versionString(),
                    buildString()
                ),
                .credits: L("about.credits"),
            ]
        )
    }

    private func versionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func buildString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    // MARK: - CmdQInterceptorDelegate

    func interceptorRequestsIntercept(frontmostBundleID: String?) -> Bool {
        // Never hold our own quit or interfere with our own windows.
        if frontmostBundleID == Bundle.main.bundleIdentifier { return false }
        return InterceptPolicy.shouldIntercept(
            enabled: settings.enabled,
            invertList: settings.invertList,
            whitelist: settings.whitelist,
            frontmostBundleID: frontmostBundleID
        )
    }

    func interceptorDidBeginHold() {
        beginSession()
    }

    func interceptorDidReceiveKeyUp() {
        // Any active session ends on release, whatever its phase.
        if engine != nil {
            endSession(cancel: true)
        }
    }

    func interceptorCommandWasReleased() {
        if engine != nil {
            endSession(cancel: true)
        }
    }

    // MARK: - Hold session

    private func beginSession() {
        guard engine == nil else {
            sessionLog.notice("session already active — ignoring begin")
            return
        }
        sessionLog.notice("session begin (delay \(self.settings.delayMilliseconds)ms)")
        let e = HoldEngine(delay: settings.delaySeconds)
        e.onFired = { [weak self] in
            self?.fireQuit()
        }
        e.begin()
        engine = e
        targetApp = NSWorkspace.shared.frontmostApplication

        if settings.displayOverlay {
            overlay.show(app: targetApp, delay: settings.delaySeconds)
            overlay.update(fraction: 0, remaining: settings.delaySeconds)
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let e = engine else { return }
        e.update()

        // Safety net: if the release notifications were ever lost (tap
        // disabled mid-session, Secure Input, …) the overlay would linger.
        // Poll the real key state and end the session ourselves.
        if e.phase == .holding {
            let commandDown = NSEvent.modifierFlags.contains(.command)
            let qDown = interceptor.qKeyIsPhysicallyDown()
            if !commandDown || (qDown == false) {
                sessionLog.notice("safety net: release detected (cmdDown=\(commandDown), qDown=\(String(describing: qDown)), elapsed=\(e.elapsed)) — cancel")
                if qDown == false {
                    interceptor.forceResetSwallowing(reason: "key state shows Q released")
                }
                endSession(cancel: true)
                return
            }
        }

        if settings.displayOverlay, e.phase == .holding {
            overlay.update(fraction: e.fraction, remaining: e.remaining)
        }
    }

    private func fireQuit() {
        // The engine has fired; stop ticking, flash the overlay, and ask the
        // frontmost app to quit gracefully.
        sessionLog.notice("session fired — quitting \(self.targetApp?.bundleIdentifier ?? "nil", privacy: .public)")
        ticker?.invalidate()
        ticker = nil

        if settings.displayOverlay {
            overlay.showCompletion()
        } else {
            overlay.hide()
        }

        let target = targetApp ?? NSWorkspace.shared.frontmostApplication
        target?.terminate()

        engine = nil
        targetApp = nil
    }

    private func endSession(cancel: Bool) {
        sessionLog.notice("session end (cancel=\(cancel))")
        ticker?.invalidate()
        ticker = nil
        engine?.cancel()
        engine = nil
        targetApp = nil
        if cancel {
            overlay.hide()
        }
    }
}

extension AppDelegate: CmdQInterceptorDelegate {}
