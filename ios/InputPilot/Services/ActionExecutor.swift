import Foundation

@MainActor protocol HIDActionTransport: AnyObject {
    func send(_ event: HIDEvent) async -> Bool
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool
    func beginOrderedSession(lowLatency: Bool) -> Bool
    func endOrderedSession()
    func releaseAllPreservingError() async
    func startPreset(program: Data, token: UInt64) async -> Bool
    func abortPreset(token: UInt64) async -> Bool
}

extension HIDActionTransport {
    func startPreset(program: Data, token: UInt64) async -> Bool { false }
    func abortPreset(token: UInt64) async -> Bool { false }
}

extension HIDConnectionManager: HIDActionTransport {}

enum ActionExecutionError: LocalizedError {
    case unsupportedCharacter(String)
    case secretMissing(String)
    case transportFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unsupportedCharacter(character): "The character ‘\(character)’ is not available in the selected host layout."
        case let .secretMissing(name): "Secret ‘\(name)’ is missing."
        case let .transportFailure(reason): reason
        case .cancelled: "Execution was cancelled."
        }
    }
}

enum MacroRecordingContext {
    @TaskLocal static var suppressed = false
}

@MainActor final class ActionExecutor {
    func run(steps: [PresetScript.Step],
             layout: KeyboardLayout,
             typingDelayMs: Int,
             token: UInt64 = UInt64.random(in: 1 ... UInt64.max),
             transport: HIDActionTransport,
             secretResolver: (String) async throws -> String) async -> Result<Void, ActionExecutionError> {
        await MacroRecordingContext.$suppressed.withValue(true) {
            await perform(steps: steps, layout: layout, typingDelayMs: typingDelayMs, token: token,
                          transport: transport, secretResolver: secretResolver)
        }
    }

    private func perform(steps: [PresetScript.Step], layout: KeyboardLayout,
                         typingDelayMs: Int, token: UInt64, transport: HIDActionTransport,
                         secretResolver: (String) async throws -> String) async -> Result<Void, ActionExecutionError> {
        do {
            var program = Data()
            var sentKeystrokes = false
            for step in steps {
                try Task.checkCancellation()
                switch step {
                case let .text(text):
                    try Self.append(text: text, layout: layout, typingDelayMs: typingDelayMs, to: &program)
                    sentKeystrokes = sentKeystrokes || !text.isEmpty
                    Self.appendDelay(50, to: &program)
                case let .key(key):
                    guard let stroke = Self.keyStroke(for: key) else {
                        return .failure(.transportFailure("The key combination ‘\(key)’ is invalid."))
                    }
                    Self.append(stroke: stroke, to: &program)
                    sentKeystrokes = true
                    Self.appendDelay(50, to: &program)
                case let .click(button):
                    Self.append(click: button, to: &program)
                    Self.appendDelay(50, to: &program)
                case let .secret(name):
                    let value: String
                    do {
                        value = try await secretResolver(name)
                    } catch is CancellationError {
                        await transport.releaseAllPreservingError()
                        return .failure(.cancelled)
                    } catch {
                        await transport.releaseAllPreservingError()
                        return .failure(.secretMissing(name))
                    }
                    do {
                        try Self.append(text: value, layout: layout, typingDelayMs: typingDelayMs, to: &program)
                    } catch {
                        await transport.releaseAllPreservingError()
                        return .failure(.transportFailure("The secret ‘\(name)’ contains a character that is not available in the selected host layout."))
                    }
                    sentKeystrokes = sentKeystrokes || !value.isEmpty
                    Self.appendDelay(50, to: &program)
                case let .delay(ms):
                    Self.appendDelay(ms, to: &program)
                }
            }
            try Task.checkCancellation()
            if sentKeystrokes { Self.appendDelay(200, to: &program) }
            if program.isEmpty { Self.appendDelay(0, to: &program) }
            guard await transport.startPreset(program: program, token: token) else {
                if Task.isCancelled {
                    _ = await transport.abortPreset(token: token)
                    return .failure(.cancelled)
                }
                return .failure(.transportFailure("The device did not accept the preset."))
            }
            // Success means the complete checksum-verified program is now
            // running independently on the ESP32, not that its final delay has
            // elapsed. This keeps App Intents well below their runtime limit.
            return .success(())
        } catch is CancellationError {
            _ = await transport.abortPreset(token: token)
            return .failure(.cancelled)
        } catch let error as KeyboardMappingError {
            switch error {
            case let .unsupported(character): return .failure(.unsupportedCharacter(String(character)))
            }
        } catch {
            return .failure(.transportFailure(error.localizedDescription))
        }
    }

    private static func append(text: String, layout: KeyboardLayout,
                               typingDelayMs: Int, to program: inout Data) throws {
        for stroke in try layout.strokes(for: text) {
            append(stroke: stroke, to: &program)
            if typingDelayMs > 0 { appendDelay(typingDelayMs, to: &program) }
        }
    }

    private static func append(stroke: HIDStroke, to program: inout Data) {
        program.append(contentsOf: [0x01, stroke.modifiers, stroke.usage])
    }

    private static func append(click button: MouseButton, to program: inout Data) {
        program.append(contentsOf: [0x03, button.rawValue])
    }

    private static func appendDelay(_ milliseconds: Int, to program: inout Data) {
        var remaining = max(0, milliseconds)
        repeat {
            let part = UInt32(min(remaining, 60_000))
            program.append(0x02)
            program.append(UInt8(part & 0xff))
            program.append(UInt8((part >> 8) & 0xff))
            program.append(UInt8((part >> 16) & 0xff))
            program.append(UInt8((part >> 24) & 0xff))
            remaining -= Int(part)
        } while remaining > 0
    }

    private static func keyStroke(for combo: String) -> HIDStroke? {
        let parts = combo.lowercased().split(whereSeparator: { $0 == "+" || $0.isWhitespace }).map(String.init)
        guard let last = parts.last else { return nil }
        var modifiers: UInt8 = 0
        for part in parts.dropLast() {
            guard let bit = modifierBit(part) else { return nil }
            modifiers |= bit
        }
        if let usage = keyUsage(last) { return HIDStroke(modifiers: modifiers, usage: usage) }
        guard let bit = modifierBit(last) else { return nil }
        return HIDStroke(modifiers: modifiers | bit, usage: 0)
    }

    private static func modifierBit(_ name: String) -> UInt8? {
        switch name {
        case "ctrl", "control": 0x01
        case "shift": 0x02
        case "alt", "opt", "option": 0x04
        case "cmd", "command", "gui", "win", "super", "meta": 0x08
        default: nil
        }
    }

    private static func keyUsage(_ name: String) -> UInt8? {
        if name.count == 1, let ascii = name.utf8.first {
            if (97 ... 122).contains(ascii) { return 0x04 + ascii - 97 }
            if (49 ... 57).contains(ascii) { return 0x1e + ascii - 49 }
            if ascii == 48 { return 0x27 }
        }
        let named: [String: UInt8] = [
            "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29,
            "backspace": 0x2a, "bksp": 0x2a, "tab": 0x2b,
            "space": 0x2c, "spacebar": 0x2c, "delete": 0x4c, "del": 0x4c,
            "insert": 0x49, "ins": 0x49, "home": 0x4a, "end": 0x4d,
            "pageup": 0x4b, "pgup": 0x4b, "pagedown": 0x4e, "pgdn": 0x4e,
            "right": 0x4f, "rightarrow": 0x4f, "left": 0x50, "leftarrow": 0x50,
            "down": 0x51, "downarrow": 0x51, "up": 0x52, "uparrow": 0x52,
            "capslock": 0x39, "caps": 0x39, "printscreen": 0x46, "prtsc": 0x46,
        ]
        if let usage = named[name] { return usage }
        if name.first == "f", let number = Int(name.dropFirst()), (1 ... 12).contains(number) {
            return UInt8(0x3a + number - 1)
        }
        return nil
    }
}
