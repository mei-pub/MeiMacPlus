import XCTest
@testable import MeiQuitManage

final class AppSettingsTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "meiquit-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testDefaultsOnFreshInstall() {
        let settings = AppSettings(defaults: suite)
        XCTAssertTrue(settings.enabled, "protection is on by default")
        XCTAssertEqual(settings.delayMilliseconds, 1000)
        XCTAssertTrue(settings.displayOverlay)
        XCTAssertFalse(settings.invertList)
        XCTAssertTrue(settings.whitelist.isEmpty)
    }

    func testWritesPersistToDefaults() {
        let settings = AppSettings(defaults: suite)
        settings.enabled = false
        settings.delayMilliseconds = 2500
        settings.displayOverlay = false
        settings.invertList = true
        settings.whitelist = ["com.apple.Notes"]

        let reloaded = AppSettings(defaults: suite)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertEqual(reloaded.delayMilliseconds, 2500)
        XCTAssertFalse(reloaded.displayOverlay)
        XCTAssertTrue(reloaded.invertList)
        XCTAssertEqual(reloaded.whitelist, ["com.apple.Notes"])
    }

    func testDelayClampedToSaneRange() {
        let settings = AppSettings(defaults: suite)
        settings.delayMilliseconds = 10
        XCTAssertEqual(settings.delayMilliseconds, AppSettings.minDelayMs)
        settings.delayMilliseconds = 999_999
        XCTAssertEqual(settings.delayMilliseconds, AppSettings.maxDelayMs)
        // The clamped values must also be what got persisted.
        XCTAssertEqual(suite.integer(forKey: "delay"), AppSettings.maxDelayMs)
    }

    func testOnChangeCallbackFires() {
        let settings = AppSettings(defaults: suite)
        var changes: [AppSettings.Change] = []
        settings.onChange = { changes.append($0) }
        settings.enabled.toggle()
        settings.displayOverlay.toggle()
        XCTAssertEqual(changes, [.enabled, .overlay])
    }

    func testDelaySecondsConversion() {
        let settings = AppSettings(defaults: suite)
        settings.delayMilliseconds = 1500
        XCTAssertEqual(settings.delaySeconds, 1.5, accuracy: 0.0001)
    }
}
