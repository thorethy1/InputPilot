import XCTest
@testable import InputPilot

@MainActor
final class AmbientBackgroundTests: XCTestCase {
    func testClockExcludesTimeOutsideActiveScene() {
        let clock = InputPilotAmbientClock()
        let start = Date(timeIntervalSince1970: 1_000)

        clock.setActive(true, at: start)
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(10)), 10)
        clock.setActive(false, at: start.addingTimeInterval(10))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(200)), 10)

        clock.setActive(true, at: start.addingTimeInterval(200))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(205)), 15)
    }

    func testRepeatedSceneNotificationsPreserveElapsedTime() {
        let clock = InputPilotAmbientClock()
        let start = Date(timeIntervalSince1970: 1_000)

        clock.setActive(true, at: start)
        clock.setActive(true, at: start.addingTimeInterval(5))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(10)), 10)
        clock.setActive(false, at: start.addingTimeInterval(10))
        clock.setActive(false, at: start.addingTimeInterval(20))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(30)), 10)
    }
}
