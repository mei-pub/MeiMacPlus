import AppKit
import os

let sessionLog = Logger(subsystem: "com.meimacplus.MeiMacPlus", category: "session")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings.shared
    private let interceptor = CmdQInterceptor()
    private let overlay = OverlayWindowController()
    private let menuBar = MenuBarController()
    let scrollEngine = ScrollEngine()

    private var permissionGuide: PermissionGuideWindowController?
    private var settingsWindow: SettingsWindowController?
    private var scrollMonitorWindow: ScrollMonitorWindowController?
    private var scriptConsoleWindow: ScriptConsoleWindowController?
    private var scriptHelpWindow: ScriptHelpWindowController?

    let scriptLogStore = ScriptLogStore()
    /// Serialized script state (dir + spoons + triggers) the running Lua
    /// environment was booted with; divergence triggers a reload.
    private var lastLoadedScriptState: String = ""

    /// Guards settings.keepAwakeOnLidClose assignments that must NOT kick
    /// off another helper round-trip (launch-time sync, revert-after-failure).
    private var applyingKeepAwake = false

    /// Active hold session, if any.
    private var engine: HoldEngine?
    private var ticker: Timer?
    private var targetApp: NSRunningApplication?
    private var trustWatchdog: Timer?
    private var lastKnownTrusted: Bool?
    private var screenLockHealTimer: Timer?

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
        syncKeepAwakeFromSystem()
        applyScrollSettings()
        applyBehavior()
        applyScriptSettings()

        let trusted = CmdQInterceptor.isProcessTrusted()
        lastKnownTrusted = trusted
        if !trusted {
            if Self.isRunningTests {
                sessionLog.notice("launch: NOT trusted, but running as XCTest host — skipping permission guide")
            } else {
                sessionLog.error("launch: NOT trusted for accessibility — showing guide")
                showPermissionGuide()
            }
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

        // Self-heal: macOS 26.2's lock-password write path is broken at the
        // OS level (root, admin GUI, profiles — everything). While the toggle
        // is on and the channel is latched broken, periodically retry the
        // FREE root path only (never prompts) so the feature activates by
        // itself the moment Apple ships a fix.
        let healer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.healScreenLockChannelIfNeeded()
            }
        }
        RunLoop.main.add(healer, forMode: .common)
        screenLockHealTimer = healer
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.healScreenLockChannelIfNeeded() }
        }
    }

    private func healScreenLockChannelIfNeeded() {
        guard settings.keepAwakeOnLidClose else { return }
        Task {
            if await KeepAwakeManager.shared.retryBrokenScreenLockChannel() {
                notifyScreenLockHealed()
            }
        }
    }

    private func notifyScreenLockHealed() {
        let notification = NSUserNotification()
        notification.title = L("keepawake.healed.title")
        notification.informativeText = L("keepawake.healed.body")
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func trustDidChange() {
        let trusted = CmdQInterceptor.isProcessTrusted()
        guard trusted != lastKnownTrusted else { return }
        lastKnownTrusted = trusted
        sessionLog.notice("trust state changed: \(trusted, privacy: .public)")
        menuBar.refresh()
        if trusted {
            activateInterceptionIfDesired()
            applyScrollSettings()
        } else {
            // Keep both taps consistent with trust; they cannot run without it.
            scrollEngine.stop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustWatchdog?.invalidate()
        interceptor.stop()
        endSession(cancel: true)
        scrollEngine.stop()
        LuaRuntime.shared.stop()
        // Process-scoped anyway; release explicitly for tidiness.
        KeepAwakeManager.shared.setDisplaySleepAssertion(false)
        VirtualDisplayManager.shared.destroy()
        // The lock-screen override MUST not outlive the app. The restore is
        // async XPC; wait for it (bounded) — applyScreenLockOverride and the
        // helper RPCs are nonisolated, so a detached task can't deadlock on
        // the main actor we're currently on.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            try? await KeepAwakeManager.shared.applyScreenLockOverride(false)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    // MARK: - Single instance

    private func ensureSingleInstance() -> Bool {
        // The unit-test host must not terminate itself when the app is
        // already running.
        guard !Self.isRunningTests else { return true }
        guard let myID = Bundle.main.bundleIdentifier else { return true }
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == myID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            NSLog("MeiMacPlus is already running (pid \(existing.processIdentifier)); activating it.")
            existing.activate()
            return false
        }
        return true
    }

    /// True when this process is the XCTest host (unit tests run in-process).
    /// The test host is ad-hoc signed and rebuilt constantly, so macOS never
    /// keeps an accessibility grant for it — it must not surface permission
    /// UI on every test run.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Host hook for `hs.urlevent`: on load it sets itself as the open-file
    /// delegate (upstream's MJAppDelegate declares this property).
    @objc private dynamic weak var openFileDelegate: NSObject?

    // MARK: - Host hooks for hs core functions (see LuaRuntime.m / HSMJStubs.m)

    @objc func menuBarIconVisible() -> Bool { menuBar.isIconVisible }
    @objc func setMenuBarIconVisible(_ visible: Bool) {
        settings.menuBarIconVisible = visible // persists via didSet
    }

    @objc func consoleFloating() -> Bool { scriptConsoleWindow?.window?.level == .floating }
    @objc func setConsoleFloating(_ floating: Bool) {
        scriptConsoleWindow?.window?.level = floating ? .floating : .normal
    }

    @objc func isLoginItemEnabled() -> Bool { LoginItemManager.isEnabled }
    @objc func setLoginItemEnabled(_ enabled: Bool) { _ = LoginItemManager.setEnabled(enabled) }

    @objc func openPreferencesWindow() { showSettings() }
    @objc func closePreferencesWindow() { settingsWindow?.window?.orderOut(nil) }

    /// NSServices handler ("Send to MeiMacPlus" service): forwards selected
    /// text to the user's hs.textDroppedToDockIconCallback, like upstream.
    @objc func processDockIconDraggedText(
        _ pboard: NSPasteboard, userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let text = pboard.string(forType: .string) else {
            error?.pointee = "no string on pasteboard"
            return
        }
        LuaRuntime.shared.notifyTextDropped(text)
    }

    /// File opens routed through hs.urlevent's openFileDelegate (mirrors
    /// upstream MJAppDelegate's application:openFiles:).
    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let sel = NSSelectorFromString("callbackWithURL:senderPID:")
        for filename in filenames {
            if let target = openFileDelegate, target.responds(to: sel) {
                target.perform(sel, with: filename as NSString, with: 0 as NSNumber)
            }
        }
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
                NSLog("MeiMacPlus: failed to toggle launch-at-login")
            }
            self.menuBar.refresh()
        }
        menuBar.onToggleKeepAwake = { [weak self] in
            self?.settings.keepAwakeOnLidClose.toggle()
        }
        menuBar.onToggleScroll = { [weak self] in
            self?.settings.scrollEnabled.toggle()
        }
        menuBar.onOpenScrollMonitor = { [weak self] in
            self?.showScrollMonitor()
        }
        menuBar.onToggleScript = { [weak self] in
            self?.settings.scriptEnabled.toggle()
        }
        menuBar.onOpenScriptConsole = { [weak self] in
            self?.showScriptConsole()
        }
        menuBar.onReloadScripts = { [weak self] in
            self?.reloadScripts()
        }
        menuBar.onOpenScriptHelp = { [weak self] in
            self?.showScriptHelp()
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
        case .keepAwake:
            applyKeepAwake()
        case .scroll:
            applyScrollSettings()
        case .script:
            applyScriptSettings()
        case .behavior:
            applyBehavior()
        default:
            break
        }
    }

    private func activateInterceptionIfDesired() {
        // The XCTest host is ad-hoc signed and rebuilt constantly, so macOS
        // treats it as a brand-new (ungranted) app on every run — creating an
        // event tap there would trigger a "Device Control & Data Access"
        // prompt per test run. The tap is never under test itself.
        guard !Self.isRunningTests else { return }
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

    // MARK: - Mouse scroll enhancement

    /// Push the current settings to the engine and reconcile its lifetime
    /// with the master switch and accessibility trust.
    private func applyScrollSettings() {
        // Same test-host rationale as activateInterceptionIfDesired: never
        // create an event tap from the ad-hoc test host.
        guard !Self.isRunningTests else { return }
        let config = ScrollConfig.from(settings)
        scrollEngine.updateConfig(config)
        guard config.enabled, CmdQInterceptor.isProcessTrusted() else {
            scrollEngine.stop()
            return
        }
        if !scrollEngine.start() {
            sessionLog.error("failed to start scroll engine")
        }
        warnAboutConflictingScrollToolsOnce()
    }

    /// Other smoothing tools (Mos, Smooze, …) fight over the same events;
    /// surface the conflict once instead of leaving the user with janky wheels.
    private func warnAboutConflictingScrollToolsOnce() {
        guard !Self.isRunningTests else { return } // never block the test host on a modal
        guard !UserDefaults.standard.bool(forKey: "scrollConflictNoticeShown") else { return }
        let known = ["com.caldis.Mos", "com.smooze.Mac.Smooze", "is.qwerty.SmoothScroll"]
        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { known.contains($0) }
        guard !running.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "scrollConflictNoticeShown")
        sessionLog.error("conflicting scroll tools running: \(running.joined(separator: ", "), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = L("scroll.conflict.title")
        alert.informativeText = L("scroll.conflict.body", running.joined(separator: ", "))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Apply the persisted behavior switches (dock icon / menu icon /
    /// console-on-top) — Hammerspoon-preferences parity. Also makes the
    /// menu-bar icon live in the status bar again after hs.menuIcon(false).
    private func applyBehavior() {
        NSApp.setActivationPolicy(
            settings.dockIconVisible ? .regular : .accessory)
        menuBar.setIconVisible(settings.menuBarIconVisible)
        if let win = scriptConsoleWindow?.window {
            win.level = settings.consoleOnTop ? .floating : .normal
        }
    }

    /// Clicking the (optional) dock icon reopens settings.
    func applicationShouldHandleReopen(_ application: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    // MARK: - Scripting

    /// Wire the Lua runtime's outputs to MeiMacPlus surfaces and reconcile
    /// its lifetime with the master switch. Skipped entirely under XCTest —
    /// tests drive LuaRuntime directly with their own config directory.
    private func applyScriptSettings() {
        let runtime = LuaRuntime.shared
        runtime.logHandler = { [weak self] line in
            self?.scriptLogStore.append(line)
        }
        runtime.openConsoleHandler = { [weak self] in
            self?.showScriptConsole()
        }
        runtime.notifyHandler = { [weak self] message in
            self?.deliverScriptNotification(message)
        }

        guard settings.scriptEnabled, !Self.isRunningTests else {
            if runtime.isRunning {
                sessionLog.notice("scripting disabled — stopping Lua runtime")
                runtime.stop()
            }
            return
        }

        let configDir = ScriptConfig.prepareConfigDir(customPath: settings.scriptCustomPath)

        // A running runtime survives only if the resolved directory, enabled
        // spoon set AND trigger configs are all unchanged; any change restarts
        // the environment instead of silently keeping the old one.
        let enabledSpoons = Set(settings.spoonsEnabled)
        let state = "\(configDir.path)|\(enabledSpoons.sorted().joined(separator: ","))|\(settings.spoonsTriggers.isEmpty ? "" : String(describing: settings.spoonsTriggers))"
        if runtime.isRunning && lastLoadedScriptState == state { return }
        if runtime.isRunning {
            sessionLog.notice("script config changed — reloading Lua runtime")
            runtime.stop()
        }
        if runtime.start(withConfigDir: configDir.path) {
            lastLoadedScriptState = state
            loadEnabledSpoons(Array(enabledSpoons), settings.spoonsTriggers)
            sessionLog.notice("Lua runtime started (config: \(configDir.path, privacy: .public))")
        } else {
            sessionLog.error("Lua runtime failed to start (vendored runtime incomplete?)")
        }
        warnAboutHammerspoonOnce()
    }

    /// hs.hotkey uses Carbon registration; when the real Hammerspoon is also
    /// running, conflicting global shortcuts fail to register on one side.
    /// Surface that once, like the scroll-tool conflict warning.
    private func warnAboutHammerspoonOnce() {
        guard !UserDefaults.standard.bool(forKey: "scriptConflictNoticeShown") else { return }
        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .contains { $0.hasPrefix("org.hammerspoon.") }
        guard running else { return }
        UserDefaults.standard.set(true, forKey: "scriptConflictNoticeShown")
        sessionLog.error("Hammerspoon is also running — hotkey conflicts possible")
        let alert = NSAlert()
        alert.messageText = L("script.conflict.title")
        alert.informativeText = L("script.conflict.body")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func deliverScriptNotification(_ message: String) {
        sessionLog.notice("script notify: \(message, privacy: .public)")
        let notification = NSUserNotification()
        notification.title = "MeiMacPlus"
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    func showScriptConsole() {
        if scriptConsoleWindow == nil {
            scriptConsoleWindow = ScriptConsoleWindowController(store: scriptLogStore)
        }
        scriptConsoleWindow?.window?.level = settings.consoleOnTop ? .floating : .normal
        scriptConsoleWindow?.present()
    }

    func showScriptHelp() {
        if scriptHelpWindow == nil {
            scriptHelpWindow = ScriptHelpWindowController()
        }
        scriptHelpWindow?.present()
    }

    func reloadScripts() {
        guard LuaRuntime.shared.isRunning else { return }
        sessionLog.notice("reloading scripts")
        LuaRuntime.shared.reload()
    }

    /// Load the enabled bundled Spoons into the freshly booted runtime.
    /// Each spoon is isolated in pcall: a broken spoon logs instead of
    /// aborting the rest. start() is called when the spoon provides it.
    private func loadEnabledSpoons(_ names: [String],
                                   _ triggers: [String: SpoonTrigger]) {
        guard !names.isEmpty else { return }
        var configs: [String] = []
        for name in names {
            // The trigger type is declared by the spoon (spoon_usage.json);
            // user settings supply only the parameters. bindHotkeys-capable
            // spoons get their OFFICIAL mapping key (toggle/show/toggleShade…).
            var mappingKey = ""
            var requires: [String] = []
            if let usage = SpoonUsageStore.usage(for: name) {
                if usage.triggers?.contains("hotkey") == true,
                   let mk = usage.mappingKey, !mk.isEmpty {
                    mappingKey = mk
                }
                requires = usage.requires ?? []
            }
            let reqList = requires.map { "'\($0)'" }.joined(separator: ",")
            var parts = ["name = '\(name)'", "mappingKey = '\(mappingKey)'",
                         "requires = {\(reqList)}"]
            if let t = triggers[name], t.type == "hotkey" {
                let mods = t.mods.map { "'\($0)'" }.joined(separator: ",")
                parts.append("mods = {\(mods)}")
                parts.append("key = '\(t.key)'")
            }
            configs.append("{ \(parts.joined(separator: ", ")) }")
        }
        let chunk =
            // hs.spoons is loaded lazily; the spoon global and hs.loadSpoon
            // only exist once it loads. Force it before anything else — at
            // boot this chunk runs first, so neither exists yet.
            "meiSpoonLoadState = 'STARTED' " +
            "spoon = spoon or {} " +
            "meiPanels = meiPanels or {} " +
            "if not meiPanelMgr then " +
            "meiPanelMgr = (function() " +
            "local mgr = {} " +
            "local esc = hs.hotkey.new({}, 'esc', function() " +
            "for _, p in ipairs(meiPanels) do if p.canvas:isShowing() then p.canvas:hide() end end " +
            "mgr.sync() end) " +
            "local tap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(e) " +
            "local pt = e:location() " +
            "for _, p in ipairs(meiPanels) do " +
            "if p.canvas:isShowing() then " +
            "local f = p.canvas:frame() " +
            "if f and not (pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h) then " +
            "p.canvas:hide() mgr.sync() return true " +
            "end " +
            "end " +
            "end " +
            "return false end) " +
            "function mgr.sync() " +
            "local any = false " +
            "for _, p in ipairs(meiPanels) do if p.canvas and p.canvas:isShowing() then any = true end end " +
            "if any then esc:start() tap:start() else esc:stop() tap:stop() end " +
            "end " +
            "function mgr.register(c) table.insert(meiPanels, {canvas = c}) end " +
            "return mgr " +
            "end)() " +
            "end " +
            "if not hs.loadSpoon then require('hs.spoons') end " +
            "local results = {} " +
            "local configs = { \(configs.joined(separator: ", ")) } " +
            "for _, cfg in ipairs(configs) do " +
            "for _, dep in ipairs(cfg.requires or {}) do " +
            "if not spoon[dep] then " +
            "local okd, depObj = pcall(hs.loadSpoon, dep) " +
            "if okd and depObj then " +
            "spoon[dep] = depObj " +
            "if depObj.start then pcall(depObj.start, depObj) end " +
            "end " +
            "end " +
            "end " +
            "local ok, sp = pcall(hs.loadSpoon, cfg.name) " +
            "if ok and sp then " +
            "if sp.canvas then meiPanelMgr.register(sp.canvas) end " +
            "local function activate() " +
            "if sp.toggle then sp:toggle() " +
            "elseif sp.toggleShow then sp:toggleShow() " +
            "elseif sp.show then sp:show() " +
            "elseif sp.run then sp:run() " +
            "else print('-- spoon ' .. cfg.name .. ' has no activatable method') end " +
            "meiPanelMgr.sync() " +
            "end " +
            "if cfg.mappingKey ~= '' and sp.bindHotkeys and cfg.key ~= '' then " +
            "local okb, errb = pcall(sp.bindHotkeys, sp, { [cfg.mappingKey] = { cfg.mods, cfg.key } }) " +
            "if not okb then print('-- spoon ' .. cfg.name .. ' bindHotkeys failed: ' .. tostring(errb)) end " +
            "elseif cfg.key ~= '' then " +
            "local okb2, errb2 = pcall(hs.hotkey.bind, cfg.mods, cfg.key, activate) " +
            "if not okb2 then print('-- spoon ' .. cfg.name .. ' hotkey bind failed: ' .. tostring(errb2)) end " +
            "end " +
            "if sp.start then pcall(sp.start, sp) end " +
            "table.insert(results, cfg.name .. '=' .. tostring(ok) .. ':' .. tostring(sp)) " +
            "else print('-- spoon ' .. cfg.name .. ' failed to load: ' .. tostring(sp)) " +
            "table.insert(results, cfg.name .. '=FAIL:' .. tostring(sp)) end " +
            "end " +
            "meiSpoonLoadState = table.concat(results, ' | ')"
        // TEMP DIAG: dump the exact chunk for offline parse-check.
        try? chunk.write(to: URL(fileURLWithPath: "/tmp/spoon-chunk.lua"), atomically: true, encoding: .utf8)
        LuaRuntime.shared.run(chunk)
    }

    // MARK: - Keep awake (lid closed)

    private func applyKeepAwake() {
        guard !applyingKeepAwake else { return }
        let desired = settings.keepAwakeOnLidClose
        sessionLog.notice("keep-awake toggle → \(desired, privacy: .public)")
        Task {
            do {
                try await KeepAwakeManager.shared.apply(desired)
                // pmset layer confirmed; now the display-sleep assertion
                // (open lid stays lit) and the virtual display (lid close
                // migrates the session onto it, so the internal panel's
                // power-off never becomes a sleep event -> no lock).
                KeepAwakeManager.shared.setDisplaySleepAssertion(desired)
                if desired {
                    VirtualDisplayManager.shared.create()
                } else {
                    VirtualDisplayManager.shared.destroy()
                }
                // Creating/destroying the virtual display reconfigures
                // screens, which can make AppKit drop our windows even with
                // stable collection behavior. Bring them back deterministically.
                await MainActor.run { restoreWindowsAfterScreenChange() }
                try await KeepAwakeManager.shared.applyScreenLockOverride(desired)
            } catch KeepAwakeManager.KeepAwakeError.cancelled {
                sessionLog.notice("keep-awake change cancelled by user")
                revertKeepAwake()
            } catch let error as KeepAwakeManager.KeepAwakeError {
                if case .screenLockChannelBroken = error {
                    // pmset + assertion + virtual display already succeeded —
                    // keep the toggle on. The limitation is documented in the
                    // settings footer; alert only the very first time.
                    sessionLog.error("screen-lock channel broken (suppression active): \(String(describing: error), privacy: .public)")
                    if !UserDefaults.standard.bool(forKey: "keepAwakeBrokenNoticeShown") {
                        UserDefaults.standard.set(true, forKey: "keepAwakeBrokenNoticeShown")
                        alertKeepAwakeFailure(error)
                    }
                } else {
                    sessionLog.error("keep-awake change failed: \(String(describing: error), privacy: .public)")
                    alertKeepAwakeFailure(error)
                    revertKeepAwake()
                }
            } catch {
                sessionLog.error("keep-awake change failed: \(String(describing: error), privacy: .public)")
                alertKeepAwakeFailure(error)
                revertKeepAwake()
            }
        }
    }

    /// Re-foreground app windows after a screen reconfiguration (virtual
    /// display create/destroy). orderFrontRegardless works even when the app
    /// itself is not active.
    private func restoreWindowsAfterScreenChange() {
        settingsWindow?.window?.orderFrontRegardless()
        scriptConsoleWindow?.window?.orderFrontRegardless()
        scrollMonitorWindow?.window?.orderFrontRegardless()
    }

    /// The toggle's stored value must reflect what the system actually does:
    /// the setting survives app quits and reboots, so at launch we read the
    /// real `pmset` state (unprivileged) and adopt it.
    private func syncKeepAwakeFromSystem() {
        Task {
            let actual = await Task.detached(priority: .utility) {
                KeepAwakeManager.readSystemDisablesSleep()
            }.value
            guard let actual else { return }
            // The user's intent (stored toggle) outranks the system state:
            // a previous apply can be interrupted (app killed mid-helper-
            // write during an update relaunch), leaving pmset stale. Re-run
            // the full apply to heal the divergence instead of silently
            // resetting the toggle to whatever pmset last said.
            if actual != settings.keepAwakeOnLidClose {
                sessionLog.notice("keep-awake diverged (system=\(actual, privacy: .public), intent=\(self.settings.keepAwakeOnLidClose, privacy: .public)) — re-applying intent")
                applyKeepAwake()
                return
            }
            // The display-sleep assertion is process-scoped and must be
            // re-created on every launch, whatever the stored value says.
            KeepAwakeManager.shared.setDisplaySleepAssertion(actual)
            // The virtual display is likewise process-scoped.
            if actual {
                VirtualDisplayManager.shared.create()
            } else {
                VirtualDisplayManager.shared.destroy()
            }
            // Lock-screen override follows; also recovers a saved pre-override
            // value if the app died while it was active.
            Task {
                try? await KeepAwakeManager.shared.applyScreenLockOverride(actual)
            }
            menuBar.refresh()
        }
    }

    /// Puts the toggle back to the (unchanged) system state.
    private func revertKeepAwake() {
        applyingKeepAwake = true
        settings.keepAwakeOnLidClose.toggle()
        applyingKeepAwake = false
        let actual = settings.keepAwakeOnLidClose
        KeepAwakeManager.shared.setDisplaySleepAssertion(actual)
        if actual {
            VirtualDisplayManager.shared.create()
        } else {
            VirtualDisplayManager.shared.destroy()
        }
        Task {
            try? await KeepAwakeManager.shared.applyScreenLockOverride(actual)
        }
        menuBar.refresh()
    }

    private func alertKeepAwakeFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("keepawake.error.title")
        alert.informativeText = L("keepawake.error.body", String(describing: error))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.present()
    }

    func showScrollMonitor() {
        if scrollMonitorWindow == nil {
            scrollMonitorWindow = ScrollMonitorWindowController(store: scrollEngine.monitor)
        }
        scrollMonitorWindow?.present()
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
