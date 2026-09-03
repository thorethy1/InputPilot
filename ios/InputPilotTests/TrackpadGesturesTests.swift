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
        XCTAssertEqual(TrackpadGestures.zoomContribution(scaleChange: 1.1), 0.1 * TrackpadGestures.zoomLinesPerFullScale, accuracy: 0.0001)
        XCTAssertEqual(TrackpadGestures.zoomContribution(scaleChange: 0.9), -0.1 * TrackpadGestures.zoomLinesPerFullScale, accuracy: 0.0001)
    }

    func testDragEngagementRequiresSustainedMovement() {
        XCTAssertFalse(TrackpadGestures.isDragEngagement(dx: 3, dy: 4))
        XCTAssertFalse(TrackpadGestures.isDragEngagement(dx: 9, dy: 0))
        XCTAssertTrue(TrackpadGestures.isDragEngagement(dx: 6, dy: 8))
        XCTAssertTrue(TrackpadGestures.isDragEngagement(dx: 0, dy: -12))
    }

    func testTwoFingerArbiterLocksScrollOnPurePan() {
        var arbiter = TwoFingerArbiter(centroidX: 0, centroidY: 0, distance: 100)
        XCTAssertNil(arbiter.update(centroidX: 5, centroidY: 5, distance: 102))
        XCTAssertNil(arbiter.update(centroidX: 11, centroidY: 0, distance: 101))
        XCTAssertEqual(arbiter.update(centroidX: 13, centroidY: 0, distance: 100), .scroll)
        XCTAssertEqual(arbiter.mode, .scroll)
        // Once locked, later geometry can never switch the mode to zoom.
        XCTAssertNil(arbiter.update(centroidX: 40, centroidY: 0, distance: 60))
        XCTAssertEqual(arbiter.mode, .scroll)
    }

    func testTwoFingerArbiterLocksZoomOnPinch() {
        var arbiter = TwoFingerArbiter(centroidX: 0, centroidY: 0, distance: 100)
        XCTAssertNil(arbiter.update(centroidX: 3, centroidY: 2, distance: 104))
        XCTAssertEqual(arbiter.update(centroidX: 4, centroidY: 2, distance: 111), .zoom)
        XCTAssertEqual(arbiter.mode, .zoom)
        // Once locked, later centroid movement can never switch to scroll.
        XCTAssertNil(arbiter.update(centroidX: 40, centroidY: 40, distance: 100))
        XCTAssertEqual(arbiter.mode, .zoom)
    }

    func testTwoFingerArbiterPinchWinsWhenBothCross() {
        var arbiter = TwoFingerArbiter(centroidX: 0, centroidY: 0, distance: 100)
        XCTAssertEqual(arbiter.update(centroidX: 15, centroidY: 0, distance: 130), .zoom)
        XCTAssertEqual(arbiter.mode, .zoom)
    }

    func testTwoFingerArbiterIgnoresJitter() {
        var arbiter = TwoFingerArbiter(centroidX: 0, centroidY: 0, distance: 100)
        XCTAssertNil(arbiter.update(centroidX: 4, centroidY: 3, distance: 95))
        XCTAssertNil(arbiter.update(centroidX: -2, centroidY: 6, distance: 108))
        XCTAssertEqual(arbiter.mode, .undetermined)
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
