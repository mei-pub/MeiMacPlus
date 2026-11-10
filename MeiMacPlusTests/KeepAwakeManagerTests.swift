import XCTest
@testable import MeiMacPlus

final class KeepAwakeManagerTests: XCTestCase {

    // parseDisablesSleep must survive the shapes `pmset -g` actually prints:
    // tab-separated settings, one per line, among unrelated keys.

    func testParsesEnabled() {
        let output = """
        System-wide power settings:
        USB charging        1
        disablesleep        1
        """
        XCTAssertEqual(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output), true)
    }

    func testParsesDisabled() {
        let output = """
        Currently in use:
        displaysleep    10
        disablesleep    0
        disksleep       10
        """
        XCTAssertEqual(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output), false)
    }

    func testMissingKeyYieldsNil() {
        let output = """
        Currently in use:
        displaysleep    10
        sleep           1
        """
        XCTAssertNil(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output))
    }

    func testEmptyAndGarbageOutputYieldsNil() {
        XCTAssertNil(KeepAwakeManager.parseDisablesSleep(pmsetOutput: ""))
        XCTAssertNil(KeepAwakeManager.parseDisablesSleep(pmsetOutput: "no keys here"))
    }

    func testOnlyTheDisablesleepLineMatters() {
        // Other keys containing "sleep" must not be mistaken for it.
        let output = """
        sleep               0
        displaysleep        2
        disablesleep        1
        """
        XCTAssertEqual(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output), true)
    }

    // macOS 26 (Tahoe) displays the key as "SleepDisabled".

    func testParsesTahoeSpelling() {
        let output = """
        System-wide power settings:
        SleepDisabled\t\t1
        Currently in use:
        sleep               1
        """
        XCTAssertEqual(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output), true)
    }

    func testParsesTahoeSpellingDisabled() {
        let output = "System-wide power settings:\n SleepDisabled\t\t0\n"
        XCTAssertEqual(KeepAwakeManager.parseDisablesSleep(pmsetOutput: output), false)
    }
}

final class ScreenLockParsingTests: XCTestCase {

    // `sysadminctl -screenLock status` prints on stderr with a timestamp
    // prefix; the parser must find the state regardless.

    func testParsesImmediate() {
        let output = "2026-11-10 08:07:09.543 sysadminctl[1877:6766892] screenLock delay is immediate"
        XCTAssertEqual(KeepAwakeManager.parseScreenLock(output), .immediate)
    }

    func testParsesSeconds() {
        let output = "2026-11-10 08:07:09.543 sysadminctl[1877:6766892] screenLock delay is 300 seconds"
        XCTAssertEqual(KeepAwakeManager.parseScreenLock(output), .delay(seconds: 300))
    }

    func testParsesOff() {
        let output = "2026-11-10 08:07:09.543 sysadminctl[1877:6766892] screenLock is off"
        XCTAssertEqual(KeepAwakeManager.parseScreenLock(output), .off)
    }

    func testUnrelatedTextIsUnknown() {
        XCTAssertEqual(KeepAwakeManager.parseScreenLock(""), .unknown)
        XCTAssertEqual(KeepAwakeManager.parseScreenLock("usage: sysadminctl"), .unknown)
    }

    func testModeArguments() {
        XCTAssertEqual(KeepAwakeManager.ScreenLockState.off.modeArgument, "off")
        XCTAssertEqual(KeepAwakeManager.ScreenLockState.immediate.modeArgument, "immediate")
        XCTAssertEqual(KeepAwakeManager.ScreenLockState.delay(seconds: 120).modeArgument, "120")
        XCTAssertEqual(KeepAwakeManager.ScreenLockState.unknown.modeArgument, "immediate")
    }
}
