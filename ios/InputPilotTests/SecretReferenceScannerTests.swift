import SwiftData
import XCTest
@testable import InputPilot

@MainActor final class SecretReferenceScannerTests: XCTestCase {
    private func makePreset(name: String, payload: String) -> HIDPreset {
        HIDPreset(name: name, payload: payload, script: true)
    }

    func testUpdateReferencesRewritesOldNameAndPreservesBracketStyle() {
        let presets = [
            makePreset(name: "Work Login", payload: "SECRET work-password\n[ENTER]"),
            makePreset(name: "Unlock PC", payload: "[SECRET work-password]\n[ENTER]"),
            makePreset(name: "Lowercase", payload: "secret work-password"),
            makePreset(name: "Other Secret", payload: "SECRET other-password\n[ENTER]"),
            makePreset(name: "Plain Text", payload: "hello world\n[CTRL+A]")
        ]

        let updated = SecretReferenceScanner.updateReferences(from: "work-password", to: "login", in: presets)

        XCTAssertEqual(updated, 3)
        XCTAssertEqual(presets[0].payload, "SECRET login\n[ENTER]")
        XCTAssertEqual(presets[1].payload, "[SECRET login]\n[ENTER]")
        XCTAssertEqual(presets[2].payload, "secret login")
        XCTAssertEqual(presets[3].payload, "SECRET other-password\n[ENTER]")
        XCTAssertEqual(presets[4].payload, "hello world\n[CTRL+A]")
    }

    func testUpdateReferencesEscapesRegexCharactersAndHandlesNamesWithDots() {
        let presets = [makePreset(name: "Dotted", payload: "SECRET my.password\n[ENTER]")]

        let updated = SecretReferenceScanner.updateReferences(from: "my.password", to: "new-name", in: presets)

        XCTAssertEqual(updated, 1)
        XCTAssertEqual(presets[0].payload, "SECRET new-name\n[ENTER]")
    }

    func testUpdateReferencesReturnsZeroWhenNothingMatches() {
        let presets = [makePreset(name: "Unrelated", payload: "SECRET unrelated")]
        XCTAssertEqual(SecretReferenceScanner.updateReferences(from: "work-password", to: "login", in: presets), 0)
        XCTAssertEqual(presets[0].payload, "SECRET unrelated")
    }

    func testFindsDirectBracketedAndCaseInsensitiveReferences() {
        let presets = [
            (name: "Work Login", payload: "SECRET work-password\n[ENTER]"),
            (name: "Unlock PC", payload: "[SECRET work-password]\n[ENTER]"),
            (name: "Lowercase", payload: "secret work-password"),
            (name: "Other Secret", payload: "SECRET other-password\n[ENTER]"),
            (name: "Plain Text", payload: "hello world\n[CTRL+A]")
        ]
        XCTAssertEqual(
            SecretReferenceScanner.presetNames(referencing: "work-password", among: presets),
            ["Work Login", "Unlock PC", "Lowercase"]
        )
    }

    func testKeepsPresetOrderAndHandlesMultipleReferences() {
        let presets = [
            (name: "Second", payload: "[TAB]\nSECRET api-token"),
            (name: "First", payload: "SECRET api-token\nSECRET api-token"),
            (name: "Unrelated", payload: "SECRET unrelated")
        ]
        XCTAssertEqual(
            SecretReferenceScanner.presetNames(referencing: "api-token", among: presets),
            ["Second", "First"]
        )
    }

    func testRegexSpecialCharactersInSecretNamesAreMatchedLiterally() {
        let presets = [(name: "Dotted", payload: "SECRET my.password")]
        XCTAssertEqual(SecretReferenceScanner.presetNames(referencing: "my.password", among: presets), ["Dotted"])
        XCTAssertEqual(SecretReferenceScanner.presetNames(referencing: "mypassword", among: presets), [])
    }
}
