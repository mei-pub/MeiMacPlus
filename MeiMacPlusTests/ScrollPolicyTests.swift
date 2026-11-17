import XCTest
@testable import MeiMacPlus

final class ScrollPolicyTests: XCTestCase {

    private func config(
        enabled: Bool = true,
        smooth: Bool = true,
        reverseV: Bool = false,
        reverseH: Bool = false,
        blacklist: Set<String> = []
    ) -> ScrollConfig {
        var c = ScrollConfig()
        c.enabled = enabled
        c.smoothEnabled = smooth
        c.reverseVertical = reverseV
        c.reverseHorizontal = reverseH
        c.blacklist = blacklist
        return c
    }

    // MARK: - Always pass through

    func testDisabledPassesEverything() {
        let decision = ScrollPolicy.decide(
            config: config(enabled: false), isContinuous: false,
            isFromSelf: false, frontmostBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(decision, .passthrough)
    }

    func testSyntheticEventsPassThrough() {
        // Our own posted events must never be re-processed, even when both
        // smoothing and reversing are on.
        let decision = ScrollPolicy.decide(
            config: config(reverseV: true), isContinuous: true,
            isFromSelf: true, frontmostBundleID: nil
        )
        XCTAssertEqual(decision, .passthrough)
    }

    func testContinuousEventsPassThrough() {
        // Trackpads and Magic Mouse.
        let decision = ScrollPolicy.decide(
            config: config(), isContinuous: true,
            isFromSelf: false, frontmostBundleID: "com.apple.Finder"
        )
        XCTAssertEqual(decision, .passthrough)
    }

    func testBlacklistedAppPassesThrough() {
        let decision = ScrollPolicy.decide(
            config: config(blacklist: ["com.apple.Terminal"]), isContinuous: false,
            isFromSelf: false, frontmostBundleID: "com.apple.Terminal"
        )
        XCTAssertEqual(decision, .passthrough)
    }

    func testUnknownFrontmostStillSmooths() {
        // No frontmost info: act (the wheel is still a discrete mouse).
        let decision = ScrollPolicy.decide(
            config: config(), isContinuous: false,
            isFromSelf: false, frontmostBundleID: nil
        )
        XCTAssertEqual(decision, .smooth)
    }

    // MARK: - Actions

    func testMouseWheelSmoothsWhenEnabled() {
        let decision = ScrollPolicy.decide(
            config: config(), isContinuous: false,
            isFromSelf: false, frontmostBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(decision, .smooth)
    }

    func testReverseWithoutSmoothingFlipsInPlace() {
        let decision = ScrollPolicy.decide(
            config: config(smooth: false, reverseV: true), isContinuous: false,
            isFromSelf: false, frontmostBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(decision, .reverseInPlace)
    }

    func testNoSmoothNoReversePassesThrough() {
        let decision = ScrollPolicy.decide(
            config: config(smooth: false), isContinuous: false,
            isFromSelf: false, frontmostBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(decision, .passthrough)
    }

    func testBlacklistCheckedBeforeAction() {
        // Even with everything enabled, a blacklisted app is untouched.
        let decision = ScrollPolicy.decide(
            config: config(smooth: true, reverseV: true, blacklist: ["com.ex.app"]),
            isContinuous: false, isFromSelf: false, frontmostBundleID: "com.ex.app"
        )
        XCTAssertEqual(decision, .passthrough)
    }
}
