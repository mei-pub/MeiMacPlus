import XCTest
@testable import MeiMacPlus

/// Config-dir resolution: an existing Hammerspoon config is reused verbatim;
/// without one we fall back to (and seed) our own directory.
final class ScriptConfigTests: XCTestCase {

    func testExistingHammerspoonConfigWins() {
        let dir = ScriptConfig.pickConfigDir(customPath: "", hammerspoonExists: true)
        XCTAssertEqual(dir, ScriptConfig.hammerspoonDirectory)
    }

    func testFallsBackToAppSupport() {
        let dir = ScriptConfig.pickConfigDir(customPath: "", hammerspoonExists: false)
        XCTAssertEqual(dir, ScriptConfig.appSupportScriptsDirectory)
    }

    func testCustomPathWinsWhenExists() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = ScriptConfig.pickConfigDir(customPath: tmp.path, hammerspoonExists: true)
        XCTAssertEqual(dir.standardizedFileURL, tmp.standardizedFileURL)
    }

    func testMissingCustomPathFallsThrough() {
        let dir = ScriptConfig.pickConfigDir(customPath: "/nonexistent-\(UUID().uuidString)",
                                              hammerspoonExists: true)
        XCTAssertEqual(dir, ScriptConfig.hammerspoonDirectory)
    }

    func testInitLuaFollowsResolvedDir() {
        XCTAssertEqual(
            ScriptConfig.pickConfigDir(customPath: "", hammerspoonExists: true)
                .appendingPathComponent("init.lua").lastPathComponent, "init.lua")
    }
}
