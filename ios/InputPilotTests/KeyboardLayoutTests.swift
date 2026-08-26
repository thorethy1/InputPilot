import XCTest
@testable import InputPilot

final class KeyboardLayoutTests: XCTestCase {
    func testGermanQWERTZAndUmlauts() throws {
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "y"), [.init(modifiers: 0, usage: 0x1d)])
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "z"), [.init(modifiers: 0, usage: 0x1c)])
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "äöüß"), [
            .init(modifiers: 0, usage: 0x34), .init(modifiers: 0, usage: 0x33),
            .init(modifiers: 0, usage: 0x2f), .init(modifiers: 0, usage: 0x2d)
        ])
    }

    func testGermanAltGrAndUppercase() throws {
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "@€\\|"), [
            .init(modifiers: 0x40, usage: 0x14), .init(modifiers: 0x40, usage: 0x08),
            .init(modifiers: 0x40, usage: 0x2d), .init(modifiers: 0x40, usage: 0x64)
        ])
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "Ä"), [.init(modifiers: 0x02, usage: 0x34)])
    }

    func testGermanRequiredSymbolsAndDigits() throws {
        let required = "0123456789!\"§$%&/()=?\\+*#'<>|^"
        XCTAssertFalse(try KeyboardLayout.german.strokes(for: required).isEmpty)
    }

    func testUSQWERTYAndUnsupportedEmoji() throws {
        XCTAssertEqual(try KeyboardLayout.us.strokes(for: "yZ"), [
            .init(modifiers: 0, usage: 0x1c), .init(modifiers: 0x02, usage: 0x1d)
        ])
        XCTAssertThrowsError(try KeyboardLayout.us.strokes(for: "🙂"))
    }

    func testEnterTabAndAllUSSymbols() throws {
        XCTAssertEqual(try KeyboardLayout.us.strokes(for: "\n\t"), [
            .init(modifiers: 0, usage: 0x28), .init(modifiers: 0, usage: 0x2b)
        ])
        XCTAssertEqual(try KeyboardLayout.us.strokes(for: "@"), [.init(modifiers: 0x02, usage: 0x1f)])
        XCTAssertFalse(try KeyboardLayout.us.strokes(for: "0123456789!@#$%^&*()_+|:\"?><{}~").isEmpty)
    }

    func testGermanAlphabetUppercaseAndCompleteRequiredSet() throws {
        XCTAssertEqual(try KeyboardLayout.german.strokes(for: "aAzZ"), [
            .init(modifiers: 0, usage: 0x04), .init(modifiers: 0x02, usage: 0x04),
            .init(modifiers: 0, usage: 0x1c), .init(modifiers: 0x02, usage: 0x1c)
        ])
        XCTAssertFalse(try KeyboardLayout.german.strokes(for: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZäöüÄÖÜß@€!\"§$%&/()=?\\+*#'<>|^0123456789").isEmpty)
    }
}
