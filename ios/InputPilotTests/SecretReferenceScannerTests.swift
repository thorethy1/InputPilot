import XCTest
@testable import InputPilot

final class SecretReferenceScannerTests: XCTestCase {
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
