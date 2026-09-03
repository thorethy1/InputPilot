import XCTest
@testable import InputPilot

final class KeyboardLatchesTests: XCTestCase {
    func testCycleProgressesOffLatchedLockedOff() {
        var latches = ModifierLatches()
        latches.cycle(KeyModifier.ctrlBit)
        XCTAssertEqual(latches.state(of: KeyModifier.ctrlBit), .latched)
        latches.cycle(KeyModifier.ctrlBit)
        XCTAssertEqual(latches.state(of: KeyModifier.ctrlBit), .locked)
        latches.cycle(KeyModifier.ctrlBit)
        XCTAssertEqual(latches.state(of: KeyModifier.ctrlBit), .off)
        XCTAssertEqual(latches.active, 0)
    }

    func testActiveCombinesLatchedAndLocked() {
        var latches = ModifierLatches()
        latches.cycle(KeyModifier.ctrlBit)
        latches.cycle(KeyModifier.shiftBit)
        latches.cycle(KeyModifier.shiftBit)
        XCTAssertEqual(latches.active, KeyModifier.ctrlBit | KeyModifier.shiftBit)
        XCTAssertEqual(latches.oneShot, KeyModifier.ctrlBit)
        XCTAssertEqual(latches.locked, KeyModifier.shiftBit)
    }

    func testLockedSurvivesOneShotConsumption() {
        var latches = ModifierLatches()
        latches.cycle(KeyModifier.shiftBit)
        latches.cycle(KeyModifier.shiftBit)
        latches.cycle(KeyModifier.ctrlBit)
        latches.consumeOneShot(bits: KeyModifier.ctrlBit)
        XCTAssertEqual(latches.oneShot, 0)
        XCTAssertEqual(latches.state(of: KeyModifier.shiftBit), .locked)
        XCTAssertEqual(latches.state(of: KeyModifier.ctrlBit), .off)
    }

    func testConsumeOneShotOnlyClearsCapturedBits() {
        var latches = ModifierLatches()
        latches.cycle(KeyModifier.ctrlBit)
        latches.cycle(KeyModifier.altBit)
        latches.consumeOneShot(bits: KeyModifier.ctrlBit)
        XCTAssertEqual(latches.state(of: KeyModifier.ctrlBit), .off)
        XCTAssertEqual(latches.state(of: KeyModifier.altBit), .latched)
    }

    func testClearResetsAllLatches() {
        var latches = ModifierLatches()
        latches.cycle(KeyModifier.ctrlBit)
        latches.cycle(KeyModifier.shiftBit)
        latches.cycle(KeyModifier.shiftBit)
        latches.clear()
        XCTAssertEqual(latches.active, 0)
        XCTAssertEqual(latches.oneShot, 0)
        XCTAssertEqual(latches.locked, 0)
    }

    func testModifierBitsMatchHIDReportLayout() {
        XCTAssertEqual(KeyModifier.ctrlBit, 0x01)
        XCTAssertEqual(KeyModifier.shiftBit, 0x02)
        XCTAssertEqual(KeyModifier.altBit, 0x04)
        XCTAssertEqual(KeyModifier.cmdBit, 0x08)
    }

    func testPacingUsesSmallChunksForShortText() {
        XCTAssertEqual(KeyboardTransmissionPacing.chunkLength(for: 0), 3)
        XCTAssertEqual(KeyboardTransmissionPacing.chunkLength(for: 119), 3)
        XCTAssertEqual(KeyboardTransmissionPacing.chunkLength(for: 120), 6)
        XCTAssertEqual(KeyboardTransmissionPacing.chunkLength(for: 400), 12)
    }

    func testPacingTickIntervalSpeedsUpForLongText() {
        XCTAssertGreaterThan(
            KeyboardTransmissionPacing.tickInterval(for: 10),
            KeyboardTransmissionPacing.tickInterval(for: 200)
        )
        XCTAssertGreaterThan(
            KeyboardTransmissionPacing.tickInterval(for: 200),
            KeyboardTransmissionPacing.tickInterval(for: 500)
        )
    }

    func testComboPresentationMapsModifiersAndKey() {
        XCTAssertEqual(KeyComboPresentation.display(for: "ctrl+c"), "⌃C")
        XCTAssertEqual(KeyComboPresentation.display(for: "ctrl+shift+z"), "⌃⇧Z")
        XCTAssertEqual(KeyComboPresentation.display(for: "cmd+space"), "⌘SPACE")
        XCTAssertEqual(KeyComboPresentation.display(for: "alt+tab"), "⌥TAB")
    }

    func testComboPresentationKeepsUnknownNames() {
        XCTAssertEqual(KeyComboPresentation.display(for: "f5"), "F5")
        XCTAssertEqual(KeyComboPresentation.display(for: "esc"), "ESC")
    }

    func testFlightLengthPrefersWholeWords() {
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "Hello world", sentPrefix: 6, isQuiet: false), 6)
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "Hello world", sentPrefix: 11, isQuiet: false), 6)
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "a  b", sentPrefix: 4, isQuiet: false), 3)
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "Hi\nthere", sentPrefix: 3, isQuiet: false), 3)
    }

    func testFlightLengthHoldsPartialWordsUntilQuiet() {
        XCTAssertNil(KeyboardTransmissionPacing.flightLength(text: "Hello", sentPrefix: 5, isQuiet: false))
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "Hello", sentPrefix: 5, isQuiet: true), 5)
        XCTAssertNil(KeyboardTransmissionPacing.flightLength(text: "Hello wor", sentPrefix: 9, isQuiet: false))
    }

    func testFlightLengthCapsRunawayInput() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(
            KeyboardTransmissionPacing.flightLength(text: long, sentPrefix: 80, isQuiet: false),
            KeyboardTransmissionPacing.visualFlightCap
        )
    }

    func testFlightLengthRequiresSentPrefixAndText() {
        XCTAssertNil(KeyboardTransmissionPacing.flightLength(text: "Hello", sentPrefix: 0, isQuiet: true))
        XCTAssertNil(KeyboardTransmissionPacing.flightLength(text: "", sentPrefix: 5, isQuiet: true))
        XCTAssertEqual(KeyboardTransmissionPacing.flightLength(text: "Hi", sentPrefix: 10, isQuiet: true), 2)
    }
}
