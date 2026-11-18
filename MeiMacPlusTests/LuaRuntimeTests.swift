import XCTest
@testable import MeiMacPlus

/// Exercises the vendored Hammerspoon runtime end-to-end: Lua state,
/// setup.lua bootstrap, native module loading (dylib dlopen under the
/// hardened-runtime entitlements), log routing, and lifecycle.
final class LuaRuntimeTests: XCTestCase {

    private var configDir: URL!
    private var logs: [String] = []

    override func setUp() {
        super.setUp()
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mei-lua-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        logs = []
        let runtime = LuaRuntime.shared
        runtime.stop()
        runtime.logHandler = { [weak self] line in
            print("[luaruntime] \(line)")
            self?.logs.append(line)
        }
        runtime.notifyHandler = nil
        runtime.openConsoleHandler = nil
    }

    override func tearDown() {
        LuaRuntime.shared.stop()
        try? FileManager.default.removeItem(at: configDir)
        super.tearDown()
    }

    private func start() {
        let ok = LuaRuntime.shared.start(withConfigDir: configDir.path)
        XCTAssertTrue(ok, "runtime should start; logs: \(logs)")
        XCTAssertTrue(LuaRuntime.shared.isRunning)
    }

    func testEvalArithmetic() throws {
        start()
        XCTAssertEqual(LuaRuntime.shared.run("return 1+1"), "2")
        XCTAssertEqual(LuaRuntime.shared.run("return 'hi'"), "hi")
    }

    func testEvalSyntaxErrorIsReported() throws {
        start()
        let result = LuaRuntime.shared.run("this is not lua(")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("syntax error") == true || result?.contains("expected") == true,
                      "expected a syntax error, got: \(result ?? "nil")")
    }

    func testNativeModuleLoads() throws {
        start()
        // hs.timer is a hybrid module: timer.lua + libtimer.dylib. Loading it
        // proves package.path, package.cpath and dylib loading all work.
        let result = LuaRuntime.shared.run("return type(hs.timer.doAfter)")
        XCTAssertEqual(result, "function", "hs.timer should load from the vendored runtime")
    }

    func testMultipleNativeModulesLoad() throws {
        start()
        let result = LuaRuntime.shared.run(
            "local ok = pcall(function() require 'hs.eventtap'; require 'hs.hotkey'; require 'hs.application' end); return tostring(ok)")
        XCTAssertEqual(result, "true")
    }

    func testPrintRoutesToLogHandler() throws {
        start()
        LuaRuntime.shared.run("print('hello from test')")
        XCTAssertTrue(logs.contains { $0.contains("hello from test") },
                      "print should reach logHandler; got: \(logs)")
    }

    func testProcessInfoDescribesHost() throws {
        start()
        let bundleID = LuaRuntime.shared.run("return hs.processInfo.bundleID") ?? ""
        XCTAssertEqual(bundleID, "com.meimacplus.MeiMacPlus")
    }

    func testSettingsRoundTrip() throws {
        start()
        LuaRuntime.shared.run("hs.settings.set('meiTestProbe', 'abc')")
        XCTAssertEqual(LuaRuntime.shared.run("return hs.settings.get('meiTestProbe')"), "abc")
    }

    func testBrokenInitLuaKeepsRuntimeRunning() throws {
        try "print('about to fail') error('boom')".write(
            toFile: configDir.appendingPathComponent("init.lua").path,
            atomically: true, encoding: .utf8)
        start()
        // A failing user config must not take the runtime down with it.
        XCTAssertTrue(LuaRuntime.shared.isRunning)
        XCTAssertTrue(logs.contains { $0.contains("about to fail") })
        XCTAssertTrue(logs.contains { $0.contains("boom") },
                      "init.lua error should surface in the log; got: \(logs)")
        XCTAssertEqual(LuaRuntime.shared.run("return 6*7"), "42")
    }

    func testStopThenRunStringReturnsNil() throws {
        start()
        LuaRuntime.shared.stop()
        XCTAssertFalse(LuaRuntime.shared.isRunning)
        XCTAssertNil(LuaRuntime.shared.run("return 1"))
    }

    func testReloadPicksUpConfigChanges() throws {
        try "probe = 'first'".write(toFile: configDir.appendingPathComponent("init.lua").path,
                                    atomically: true, encoding: .utf8)
        try start()
        XCTAssertEqual(LuaRuntime.shared.run("return probe"), "first")

        try "probe = 'second'".write(toFile: configDir.appendingPathComponent("init.lua").path,
                                     atomically: true, encoding: .utf8)
        LuaRuntime.shared.reload()
        XCTAssertTrue(LuaRuntime.shared.isRunning)
        XCTAssertEqual(LuaRuntime.shared.run("return probe"), "second")
    }

    /// Every vendored hs.* module must at least `require` cleanly — this is
    /// the regression gate for host-symbol gaps (see HSMJStubs.m) and for
    /// the excluded-networking list in scripts/fetch_hs_runtime.sh.
    /// Hotkey-capable spoons must activate via their OFFICIAL bindHotkeys
    /// mapping (user report: "-- spoon ClipShow has no toggle/show/run").
    func testSpoonTriggerBinding() throws {
        try start()
        // Caffeine exposes :bindHotkeys({toggle=…}) and :toggle().
        let r1 = LuaRuntime.shared.run(
            "local ok, sp = pcall(hs.loadSpoon, 'Caffeine'); " +
            "if not ok or not sp then return 'LOADFAIL' end " +
            "local okb, err = pcall(sp.bindHotkeys, sp, { toggle = { {'cmd','alt'}, 'c' } }); " +
            "return okb and 'BOUND' or tostring(err)")
        XCTAssertEqual(r1, "BOUND", "Caffeine bindHotkeys failed: \(r1 ?? "nil") logs: \(logs.suffix(6))")
        // ClipShow has :toggleShow (covered by the loader's activate chain),
        // and depends on the ModalMgr spoon global (user report: nil index
        // at fillModalKeys). Preload it the way the loader does.
        let r2 = LuaRuntime.shared.run(
            "if not spoon.ModalMgr then " +
            "spoon.ModalMgr = hs.loadSpoon('ModalMgr') " +
            "if spoon.ModalMgr.start then spoon.ModalMgr:start() end " +
            "end " +
            "local ok, sp = pcall(hs.loadSpoon, 'ClipShow'); " +
            "if not ok or not sp then return 'LOADFAIL' end " +
            "return (type(sp.toggleShow) == 'function' and spoon.ModalMgr ~= nil) and 'OK' or 'MISSING'")
        XCTAssertEqual(r2, "OK", "ClipShow with ModalMgr preload failed: \(r2 ?? "nil") logs: \(logs.suffix(6))")
    }

    /// hs.chooser.new instantiates its window from the HSChooserWindow.nib
    /// vendored into Resources; without the nib it silently returns nil.
    func testChooserInstanceCreation() throws {
        try start()
        let result = LuaRuntime.shared.run(
            "local c = hs.chooser.new(function() end); " +
            "if c == nil then return 'NIL' else c:delete(); return 'OK' end")
        XCTAssertEqual(result, "OK", "hs.chooser.new returned nil — nib missing? logs: \(logs.suffix(5))")
    }

    func testAllVendoredModulesLoad() throws {
        try start()

        // Modules that would trigger TCC prompts or are known-excluded
        // (their dylibs are not vendored; see fetch_hs_runtime.sh).
        let skip: Set<String> = [
            "location",       // starting the location manager prompts for permission
            // Loading hs.keycodes (directly or via eventtap/hotkey/...) reads
            // the hardware keyboard layout at module load, which prompts for
            // "Device Control & Data Access" on an ungranted process — the
            // ad-hoc test host would pop a system dialog on every run.
            // Granted apps load these normally.
            "keycodes", "eventtap", "hotkey", "expose", "grid", "hints",
            "mouse", "spoons",
        ]

        let listing = LuaRuntime.shared.run("""
            local names = {}
            for name in pairs(hs._extensions) do table.insert(names, name) end
            table.sort(names)
            return table.concat(names, ',')
            """) ?? ""
        XCTAssertFalse(listing.isEmpty, "hs._extensions should list vendored modules")

        var failed: [String] = []
        for name in listing.split(separator: ",") where !skip.contains(String(name)) {
            let result = LuaRuntime.shared.run(
                "local ok, err = pcall(require, 'hs.\(name)'); " +
                "if ok then return 'OK' else return tostring(err) end") ?? "?"
            if result != "OK" {
                failed.append("\(name): \(result)")
            }
        }
        XCTAssertTrue(failed.isEmpty, "modules failed to load:\n\(failed.joined(separator: "\n"))")
    }
}

/// The vendored runtime's non-obvious bundle dependencies: native modules
/// load them from Resources/Frameworks at runtime. Any of these missing
/// degrades a specific hs.* feature silently — this test keeps the fetch
/// pipeline honest.
final class HSRuntimeBundleContentsTests: XCTestCase {

    private var resourcePath: String { Bundle.main.resourcePath ?? "" }
    private var frameworksPath: String {
        Bundle.main.privateFrameworksPath ?? ""
    }

    func testChooserNibExists() {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resourcePath + "/HSChooserWindow.nib"),
                      "hs.chooser.new silently returns nil without the nib")
    }

    func testHsminwebCGIToolExists() {
        let url = URL(fileURLWithPath: resourcePath + "/timeout3")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testIpcCliAssetsExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: resourcePath + "/man/hs.man"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: frameworksPath + "/hs/hs"))
    }

    func testInfoplistPrivacyAndURLKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(info["NSAppTransportSecurity"], "ATS exception missing — hs.http to http:// breaks")
        XCTAssertEqual(info["NSAppSleepDisabled"] as? Bool, true, "App Nap would throttle hs.timer/watchers")
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSLocationAlwaysUsageDescription", "NSAppleEventsUsageDescription"] {
            XCTAssertNotNil(info[key], "\(key) missing — TCC denies the matching hs.* module outright")
        }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(schemes.contains("hammerspoon"), "hammerspoon:// scheme missing for hs.urlevent")
    }

    func testRuntimeHostDylibExports() throws {
        // Spot-check the flat-namespace host symbols hs.* dylibs bind to.
        let dylib = frameworksPath + "/MeiHSRuntime.dylib"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dylib))
        let output = try Process.runAndCapture(nm: dylib)
        for symbol in ["HSapplication", "MJConsoleWindowController", "GCDAsyncSocket",
                       "SRWebSocket", "HTTPServer", "ORSSerialPort", "MIKMIDIDeviceManager"] {
            XCTAssertTrue(output.contains(symbol), "MeiHSRuntime.dylib missing \(symbol)")
        }
    }
}

private extension Process {
    static func runAndCapture(nm path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// hs core functions that drive host integration (menu icon, AppleScript
/// gate, console appearance) must round-trip and persist.
final class HostIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "HSAppleScriptEnabledKey")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "HSAppleScriptEnabledKey")
        super.tearDown()
    }

    private func startRuntime() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mei-host-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        LuaRuntime.shared.stop()
        XCTAssertTrue(LuaRuntime.shared.start(withConfigDir: dir.path))
    }

    func testAllowAppleScriptRoundTrip() {
        startRuntime()
        XCTAssertEqual(LuaRuntime.shared.run("return hs.allowAppleScript()"), "false")
        LuaRuntime.shared.run("hs.allowAppleScript(true)")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "HSAppleScriptEnabledKey"),
                      "hs.allowAppleScript(true) must persist the gate")
        XCTAssertEqual(LuaRuntime.shared.run("return hs.allowAppleScript()"), "true")
    }

    func testMenuIconToggleDoesNotCrash() {
        startRuntime()
        XCTAssertEqual(LuaRuntime.shared.run("return tostring(hs.menuIcon(false))"), "false")
        XCTAssertEqual(LuaRuntime.shared.run("return tostring(hs.menuIcon(true))"), "true")
    }

    func testConsoleAppearanceIsReadableFromHost() throws {
        startRuntime()
        LuaRuntime.shared.run("hs.console.consoleCommandColor{red=1}")
        let cls = try XCTUnwrap(NSClassFromString("MJConsoleWindowController") as? NSObject.Type)
        let singleton = try XCTUnwrap(
            cls.perform(NSSelectorFromString("singleton"))?.takeUnretainedValue() as? NSObject)
        let color = try XCTUnwrap(singleton.value(forKey: "MJColorForCommand") as? NSColor)
        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.01)
    }

    func testAppleScriptAndServiceAssetsExist() throws {
        let bundle = Bundle.main
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.path(forResource: "MeiMacPlus", ofType: "sdef") ?? "/missing"),
                      "scripting definition missing — `tell app \"MeiMacPlus\"` won't work")
        XCTAssertNotNil(bundle.path(forResource: "PrivacyInfo", ofType: "xcprivacy"))
        let info = try XCTUnwrap(bundle.infoDictionary)
        XCTAssertEqual(info["NSAppleScriptEnabled"] as? Bool, true)
        XCTAssertFalse((info["NSServices"] as? [[String: Any]] ?? []).isEmpty,
                       "Send-to-MeiMacPlus service missing")
    }
}

/// The bilingual scripting help (bundled HTML + vendored docs.json) must be
/// present — the help window is the primary docs surface for script users.
final class ScriptHelpAssetsTests: XCTestCase {
    func testHelpAssetsExist() {
        let bundle = Bundle.main
        let resources = bundle.resourceURL ?? URL(fileURLWithPath: "/missing")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("ScriptHelp.index.html").path),
                      "help page missing")
        // The modules/API tabs read window.__DOCS__ from this file (WKWebView
        // cannot fetch() file:// URLs).
        let dataPath = resources.appendingPathComponent("ScriptHelp.data.js").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataPath),
                      "help data missing — Modules/API tabs would be empty")
        // Spoons tab content is baked into the page.
        let html = (try? String(contentsOf: resources.appendingPathComponent("ScriptHelp.index.html"), encoding: .utf8)) ?? ""
        XCTAssertTrue(html.contains("SpoonInstall"), "Spoons tab data missing")
        // Spoons detail data + zh map ship as JS files (WKWebView can't fetch()).
        for js in ["ScriptSpoons.data.js"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: resources.appendingPathComponent(js).path), "\(js) missing")
        }
        let spoonDirs = (try? FileManager.default.contentsOfDirectory(
            atPath: resources.appendingPathComponent("spoons").path)) ?? []
        XCTAssertGreaterThanOrEqual(spoonDirs.filter { $0.hasSuffix(".spoon") }.count, 89,
                                    "bundled spoons missing")
        if let head = try? String(contentsOfFile: dataPath, encoding: .utf8).prefix(30) {
            XCTAssertTrue(head.hasPrefix("window.__DOCS__="), "data.js has no assignment prefix")
        }
        XCTAssertNotNil(bundle.url(forResource: "docs", withExtension: "json"),
                        "docs.json missing — API reference would be empty")
    }
}
