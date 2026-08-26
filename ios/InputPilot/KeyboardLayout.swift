import Foundation

struct HIDStroke: Equatable, Sendable {
    let modifiers: UInt8
    let usage: UInt8

    static let shift: UInt8 = 0x02
    static let altGr: UInt8 = 0x40
}

enum KeyboardLayout: String, CaseIterable, Identifiable, Sendable {
    case german = "German QWERTZ"
    case us = "US QWERTY"

    var id: String { rawValue }

    func strokes(for text: String) throws -> [HIDStroke] {
        try text.flatMap { character in
            guard let strokes = strokes(for: character) else {
                throw KeyboardMappingError.unsupported(character)
            }
            return strokes
        }
    }

    func strokes(for character: Character) -> [HIDStroke]? {
        if character == "\n" || character == "\r" { return [HIDStroke(modifiers: 0, usage: 0x28)] }
        if character == "\t" { return [HIDStroke(modifiers: 0, usage: 0x2b)] }
        if character == " " { return [HIDStroke(modifiers: 0, usage: 0x2c)] }
        return self == .german ? germanStrokes(for: character) : usStrokes(for: character)
    }

    private func letter(_ character: Character, swapYZ: Bool) -> [HIDStroke]? {
        let value = String(character)
        let lower = value.lowercased()
        guard lower.count == 1, let ascii = lower.utf8.first, ascii >= 97, ascii <= 122 else { return nil }
        var usage = UInt8(0x04 + ascii - 97)
        if swapYZ && lower == "y" { usage = 0x1d }
        if swapYZ && lower == "z" { usage = 0x1c }
        let shifted = value != lower
        return [HIDStroke(modifiers: shifted ? HIDStroke.shift : 0, usage: usage)]
    }

    private func germanStrokes(for character: Character) -> [HIDStroke]? {
        if let result = letter(character, swapYZ: true) { return result }
        let shift = HIDStroke.shift, altGr = HIDStroke.altGr
        let map: [Character: HIDStroke] = [
            "1": .init(modifiers: 0, usage: 0x1e), "2": .init(modifiers: 0, usage: 0x1f),
            "3": .init(modifiers: 0, usage: 0x20), "4": .init(modifiers: 0, usage: 0x21),
            "5": .init(modifiers: 0, usage: 0x22), "6": .init(modifiers: 0, usage: 0x23),
            "7": .init(modifiers: 0, usage: 0x24), "8": .init(modifiers: 0, usage: 0x25),
            "9": .init(modifiers: 0, usage: 0x26), "0": .init(modifiers: 0, usage: 0x27),
            "ä": .init(modifiers: 0, usage: 0x34), "Ä": .init(modifiers: shift, usage: 0x34),
            "ö": .init(modifiers: 0, usage: 0x33), "Ö": .init(modifiers: shift, usage: 0x33),
            "ü": .init(modifiers: 0, usage: 0x2f), "Ü": .init(modifiers: shift, usage: 0x2f),
            "ß": .init(modifiers: 0, usage: 0x2d), "@": .init(modifiers: altGr, usage: 0x14),
            "€": .init(modifiers: altGr, usage: 0x08), "!": .init(modifiers: shift, usage: 0x1e),
            "\"": .init(modifiers: shift, usage: 0x1f), "§": .init(modifiers: shift, usage: 0x20),
            "$": .init(modifiers: shift, usage: 0x21), "%": .init(modifiers: shift, usage: 0x22),
            "&": .init(modifiers: shift, usage: 0x23), "/": .init(modifiers: shift, usage: 0x24),
            "(": .init(modifiers: shift, usage: 0x25), ")": .init(modifiers: shift, usage: 0x26),
            "=": .init(modifiers: shift, usage: 0x27), "?": .init(modifiers: shift, usage: 0x2d),
            "\\": .init(modifiers: altGr, usage: 0x2d), "+": .init(modifiers: 0, usage: 0x30),
            "*": .init(modifiers: shift, usage: 0x30), "#": .init(modifiers: 0, usage: 0x31),
            "'": .init(modifiers: shift, usage: 0x31), "<": .init(modifiers: 0, usage: 0x64),
            ">": .init(modifiers: shift, usage: 0x64), "|": .init(modifiers: altGr, usage: 0x64),
            "-": .init(modifiers: 0, usage: 0x38), "_": .init(modifiers: shift, usage: 0x38),
            ",": .init(modifiers: 0, usage: 0x36), ";": .init(modifiers: shift, usage: 0x36),
            ".": .init(modifiers: 0, usage: 0x37), ":": .init(modifiers: shift, usage: 0x37)
        ]
        if character == "^" { return [.init(modifiers: 0, usage: 0x35), .init(modifiers: 0, usage: 0x2c)] }
        return map[character].map { [$0] }
    }

    private func usStrokes(for character: Character) -> [HIDStroke]? {
        if let result = letter(character, swapYZ: false) { return result }
        let shifted = "!@#$%^&*()_+|:\"?><{}~"
        let plain = "1234567890-=\\;'/.,[]`"
        let usages: [UInt8] = [0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x2d,0x2e,0x31,0x33,0x34,0x38,0x37,0x36,0x2f,0x30,0x35]
        if let index = plain.firstIndex(of: character) { return [.init(modifiers: 0, usage: usages[plain.distance(from: plain.startIndex, to: index)])] }
        if let index = shifted.firstIndex(of: character) { return [.init(modifiers: HIDStroke.shift, usage: usages[shifted.distance(from: shifted.startIndex, to: index)])] }
        return nil
    }
}

enum KeyboardMappingError: LocalizedError, Equatable {
    case unsupported(Character)
    var errorDescription: String? {
        switch self { case let .unsupported(character): "The character ‘\(character)’ is not available in the selected host layout." }
    }
}
