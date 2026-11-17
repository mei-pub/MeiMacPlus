import XCTest
@testable import MeiMacPlus

final class ScrollSmootherTests: XCTestCase {

    private let tick: TimeInterval = 1.0 / 90.0

    /// Drain an axis to zero with fixed-size ticks; returns the total emitted.
    private func drain(_ axis: inout ScrollAxisSmoother, maxTicks: Int = 2000) -> Int {
        var total = 0
        var ticks = 0
        while axis.isActive && ticks < maxTicks {
            total += axis.advance(dt: tick)
            ticks += 1
        }
        return total
    }

    // MARK: - Conservation

    func testOutputConservesInputDistance() {
        for durationMS in [100, 300, 600, 1000] {
            var axis = ScrollAxisSmoother(duration: TimeInterval(durationMS) / 1000)
            axis.feed(100)
            let emitted = drain(&axis)
            XCTAssertEqual(emitted, 100, "duration \(durationMS)ms should preserve distance")
        }
    }

    func testConservesAcrossRepeatedFeeds() {
        var axis = ScrollAxisSmoother(duration: 0.3)
        // Fire pulses in bursts with some draining in between.
        axis.feed(40)
        var emitted = axis.advance(dt: tick * 4)
        axis.feed(35)
        emitted += axis.advance(dt: tick * 10)
        axis.feed(25)
        emitted += drain(&axis)
        XCTAssertEqual(emitted, 100, accuracy: 1)
    }

    func testNegativeDirectionConserved() {
        var axis = ScrollAxisSmoother(duration: 0.3)
        axis.feed(-80)
        let emitted = drain(&axis)
        XCTAssertEqual(emitted, -80)
    }

    func testOppositePulseBrakesAndReverses() {
        var axis = ScrollAxisSmoother(duration: 0.3)
        axis.feed(100)
        // Immediately countermand: net distance is -20.
        axis.feed(-120)
        let emitted = drain(&axis)
        XCTAssertEqual(emitted, -20, accuracy: 1)
    }

    // MARK: - Timing behavior

    func testEarlyTicksEmitMoreThanLateTicks() {
        var axis = ScrollAxisSmoother(duration: 0.3)
        axis.feed(1000)

        var early = 0
        for _ in 0..<3 { early += axis.advance(dt: tick) }
        var middle = 0
        for _ in 0..<30 { middle += axis.advance(dt: tick) }
        var late = 0
        for _ in 0..<30 { late += axis.advance(dt: tick) }

        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(middle, late, "easing must decay over time")
        XCTAssertEqual(early + middle + late + drain(&axis), 1000, accuracy: 1)
    }

    func testLargeDtDoesNotExplode() {
        var axis = ScrollAxisSmoother(duration: 0.3)
        axis.feed(500)
        let emitted = axis.advance(dt: 10) // stalled run loop
        XCTAssertEqual(emitted, 500, "a huge dt releases the whole remainder")
        XCTAssertFalse(axis.isActive)
    }

    func testSettlesBelowHalfPixel() {
        var axis = ScrollAxisSmoother(duration: 0.05)
        axis.feed(3)
        _ = drain(&axis)
        XCTAssertFalse(axis.isActive, "must settle to exactly zero")
        XCTAssertEqual(axis.advance(dt: tick), 0, "idle advances emit nothing")
    }

    // MARK: - Dual-axis container

    func testAxesAreIndependent() {
        var smoother = ScrollSmoother(durationMS: 200)
        smoother.feed(dy: 50, dx: -30)
        XCTAssertTrue(smoother.isActive)

        var dyTotal = 0
        var dxTotal = 0
        var ticks = 0
        while smoother.isActive && ticks < 2000 {
            let out = smoother.advance(dt: tick)
            dyTotal += out.dy
            dxTotal += out.dx
            ticks += 1
        }
        XCTAssertEqual(dyTotal, 50, accuracy: 1)
        XCTAssertEqual(dxTotal, -30, accuracy: 1)
    }

    func testCancelDropsPendingDistance() {
        var smoother = ScrollSmoother(durationMS: 300)
        smoother.feed(dy: 100, dx: 0)
        smoother.cancel()
        XCTAssertFalse(smoother.isActive)
        let out = smoother.advance(dt: tick)
        XCTAssertEqual(out.dy, 0)
        XCTAssertEqual(out.dx, 0)
    }

    func testDurationUpdateKeepsPendingAmount() {
        var smoother = ScrollSmoother(durationMS: 400)
        smoother.feed(dy: 60, dx: 0)
        var dyTotal = smoother.advance(dt: tick).dy
        smoother.updateDuration(ms: 120)
        XCTAssertTrue(smoother.isActive)
        var ticks = 0
        while smoother.isActive && ticks < 2000 {
            dyTotal += smoother.advance(dt: tick).dy
            ticks += 1
        }
        XCTAssertEqual(dyTotal, 60, accuracy: 1)
    }
}
