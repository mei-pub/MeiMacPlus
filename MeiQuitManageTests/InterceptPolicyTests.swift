import XCTest
@testable import MeiQuitManage

final class InterceptPolicyTests: XCTestCase {

    private let list = ["com.apple.Notes", "com.google.Chrome"]

    func testDisabledNeverIntercepts() {
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: false, invertList: false, whitelist: list, frontmostBundleID: "com.apple.Safari"))
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: false, invertList: true, whitelist: list, frontmostBundleID: "com.apple.Notes"))
    }

    func testUnknownFrontmostPassesThrough() {
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: false, whitelist: list, frontmostBundleID: nil))
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: false, whitelist: list, frontmostBundleID: ""))
    }

    func testNormalModeProtectsEverythingExceptListed() {
        XCTAssertTrue(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: false, whitelist: list, frontmostBundleID: "com.apple.Safari"))
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: false, whitelist: list, frontmostBundleID: "com.apple.Notes"))
        XCTAssertTrue(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: false, whitelist: [], frontmostBundleID: "com.apple.Safari"))
    }

    func testInvertedModeProtectsOnlyListed() {
        XCTAssertTrue(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: true, whitelist: list, frontmostBundleID: "com.google.Chrome"))
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: true, whitelist: list, frontmostBundleID: "com.apple.Safari"))
        XCTAssertFalse(InterceptPolicy.shouldIntercept(
            enabled: true, invertList: true, whitelist: [], frontmostBundleID: "com.apple.Safari"))
    }
}
