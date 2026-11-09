import XCTest
@testable import MeiMacPlus

final class HoldEngineTests: XCTestCase {

    private final class ManualClock {
        var time: TimeInterval = 0
    }

    private func makeEngine(delay: TimeInterval, clock: ManualClock, file: StaticString = #filePath, line: UInt = #line) -> HoldEngine {
        guard delay > 0 else {
            XCTFail("delay must be positive", file: file, line: line)
            return HoldEngine(delay: 0.01, now: { clock.time })
        }
        return HoldEngine(delay: delay, now: { clock.time })
    }

    func testBeginStartsHolding() {
        let clock = ManualClock()
        let engine = makeEngine(delay: 1.0, clock: clock)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(engine.begin())
        XCTAssertEqual(engine.phase, .holding)
        XCTAssertFalse(engine.begin(), "second begin must be rejected")
    }

    func testFractionAndRemainingProgress() {
        let clock = ManualClock()
        let engine = makeEngine(delay: 2.0, clock: clock)
        engine.begin()

        clock.time = 1.0
        XCTAssertEqual(engine.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(engine.remaining, 1.0, accuracy: 0.0001)

        clock.time = 1.9
        XCTAssertEqual(engine.fraction, 0.95, accuracy: 0.0001)
    }

    func testFiresExactlyOnceAtThreshold() {
        let clock = ManualClock()
        let engine = makeEngine(delay: 1.0, clock: clock)
        var firedCount = 0
        engine.onFired = { firedCount += 1 }

        engine.begin()
        clock.time = 0.999
        engine.update()
        XCTAssertEqual(engine.phase, .holding, "must not fire early")
        XCTAssertEqual(firedCount, 0)

        clock.time = 1.0
        engine.update()
        XCTAssertEqual(engine.phase, .fired)
        XCTAssertEqual(firedCount, 1)
        XCTAssertEqual(engine.fraction, 1.0, accuracy: 0.0001)

        // Extra ticks and even time going backwards must not re-fire.
        clock.time = 1.5
        engine.update()
        engine.update()
        XCTAssertEqual(firedCount, 1)
    }

    func testCancelResetsToIdle() {
        let clock = ManualClock()
        let engine = makeEngine(delay: 1.0, clock: clock)
        engine.begin()
        clock.time = 0.5
        engine.cancel()
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.fraction, 0)
        XCTAssertEqual(engine.elapsed, 0)
        XCTAssertTrue(engine.begin(), "must allow a fresh session after cancel")
    }

    func testCancelAfterFireIsHarmless() {
        let clock = ManualClock()
        let engine = makeEngine(delay: 0.5, clock: clock)
        engine.begin()
        clock.time = 0.5
        engine.update()
        XCTAssertEqual(engine.phase, .fired)
        engine.cancel()
        XCTAssertEqual(engine.phase, .idle)
    }
}
