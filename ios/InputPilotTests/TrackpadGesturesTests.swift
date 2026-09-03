import XCTest
@testable import InputPilot

final class TrackpadGesturesTests: XCTestCase {
    func testFractionalAccumulatorPreservesSubPixelMovement() {
        var accumulator = FractionalAccumulator()
        XCTAssertEqual(accumulator.add(0.9), 0)
        XCTAssertEqual(accumulator.add(0.9), 1)
        XCTAssertEqual(accumulator.residue, 0.8, accuracy: 0.0001)
    }

    func testFractionalAccumulatorHandlesNegativeDeltas() {
        var accumulator = FractionalAccumulator()
        XCTAssertEqual(accumulator.add(-0.9), 0)
        XCTAssertEqual(accumulator.add(-0.9), -1)
        XCTAssertEqual(accumulator.residue, -0.8, accuracy: 0.0001)
    }

    func testFractionalAccumulatorFlushEmitsRemainderAndResets() {
        var accumulator = FractionalAccumulator()
        XCTAssertEqual(accumulator.add(0.7), 0)
        XCTAssertEqual(accumulator.flush(), 1)
        XCTAssertEqual(accumulator.flush(), 0)
        XCTAssertEqual(accumulator.add(0.7), 0)
    }

    func testPointerAccumulatorEmitsIndependentAxes() {
        var accumulator = PointerAccumulator()
        let first = accumulator.add(dx: 1.4, dy: -0.4)
        XCTAssertEqual(first.x, 1)
        XCTAssertEqual(first.y, 0)
        let second = accumulator.add(dx: 0, dy: -0.7)
        XCTAssertEqual(second.x, 0)
        XCTAssertEqual(second.y, -1)
    }

    func testScrollContributionNaturalInvertsPanDirection() {
        XCTAssertEqual(TrackpadGestures.scrollContribution(panDeltaY: 10, natural: true), -2, accuracy: 0.0001)
        XCTAssertEqual(TrackpadGestures.scrollContribution(panDeltaY: 10, natural: false), 2, accuracy: 0.0001)
        XCTAssertEqual(TrackpadGestures.scrollContribution(panDeltaY: -5, natural: true), 1, accuracy: 0.0001)
    }

    func testZoomContributionZoomsInOnScaleUp() {
        XCTAssertEqual(TrackpadGestures.zoomContribution(scaleChange: 1.0), 0, accuracy: 0.0001)
        XCTAssertEqual(TrackpadGestures.zoomContribution(scaleChange: 1.1), 1, accuracy: 0.0001)
        XCTAssertEqual(TrackpadGestures.zoomContribution(scaleChange: 0.9), -1, accuracy: 0.0001)
    }

    func testMomentumGeneratorDecaysToFinish() {
        var generator = MomentumGenerator(velocity: 3000, natural: true)
        var emitted = 0
        var guardCounter = 0
        while !generator.isFinished {
            emitted += abs(generator.nextLine())
            guardCounter += 1
            XCTAssertLessThan(guardCounter, 1000, "Momentum must decay to a stop")
        }
        XCTAssertGreaterThan(emitted, 0, "Momentum should emit scroll lines")
        XCTAssertEqual(generator.nextLine(), 0)
    }

    func testMomentumGeneratorDirectionFollowsNaturalSetting() {
        var natural = MomentumGenerator(velocity: 1000, natural: true)
        var traditional = MomentumGenerator(velocity: 1000, natural: false)
        let firstNatural = natural.nextLine()
        let firstTraditional = traditional.nextLine()
        XCTAssertLessThan(firstNatural, 0)
        XCTAssertGreaterThan(firstTraditional, 0)
    }

    func testMomentumGeneratorIgnoresSlowVelocity() {
        var generator = MomentumGenerator(velocity: 20, natural: true)
        XCTAssertTrue(generator.isFinished)
        XCTAssertEqual(generator.nextLine(), 0)
    }

    func testGestureStateOverlayTitles() {
        XCTAssertEqual(TrackpadGestureState.idle.overlayTitle, "Trackpad")
        XCTAssertEqual(TrackpadGestureState.moving.overlayTitle, "Moving")
        XCTAssertEqual(TrackpadGestureState.scrolling.overlayTitle, "Scrolling")
        XCTAssertEqual(TrackpadGestureState.dragging.overlayTitle, "Dragging")
        XCTAssertEqual(TrackpadGestureState.zooming.overlayTitle, "Zooming")
    }
}
