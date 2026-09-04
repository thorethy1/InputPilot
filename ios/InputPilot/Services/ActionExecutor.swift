import Foundation

@MainActor protocol HIDActionTransport: AnyObject {
    func send(_ event: HIDEvent) async -> Bool
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool
    func beginOrderedSession(lowLatency: Bool) -> Bool
    func endOrderedSession()
    func releaseAllPreservingError() async
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

@MainActor final class ActionExecutor {
    func run(steps: [PresetScript.Step],
             layout: KeyboardLayout,
             typingDelayMs: Int,
             transport: HIDActionTransport,
             secretResolver: (String) async throws -> String) async -> Result<Void, ActionExecutionError> {
        for step in steps {
            guard case let .text(text) = step else { continue }
            do {
                _ = try layout.strokes(for: text)
            } catch let error as KeyboardMappingError {
                switch error {
                case let .unsupported(character): return .failure(.unsupportedCharacter(String(character)))
                }
            } catch {
                return .failure(.transportFailure(error.localizedDescription))
            }
        }
        guard transport.beginOrderedSession(lowLatency: false) else {
            return .failure(.transportFailure("The device is not ready to receive input."))
        }
        defer { transport.endOrderedSession() }
        do {
            for step in steps {
                try Task.checkCancellation()
                let sent: Bool
                switch step {
                case let .text(text): sent = await transport.sendText(text, layout: layout, delayMilliseconds: typingDelayMs)
                case let .key(key): sent = await transport.send(.keyCombo(key))
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
                        _ = try layout.strokes(for: value)
                    } catch {
                        await transport.releaseAllPreservingError()
                        return .failure(.transportFailure("The secret ‘\(name)’ contains a character that is not available in the selected host layout."))
                    }
                    sent = await transport.sendText(value, layout: layout, delayMilliseconds: typingDelayMs)
                case let .delay(ms): try await Task.sleep(for: .milliseconds(ms)); continue
                }
                guard sent else {
                    await transport.releaseAllPreservingError()
                    return .failure(.transportFailure("The device did not accept the action."))
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            await transport.releaseAllPreservingError()
            return .success(())
        } catch is CancellationError {
            await transport.releaseAllPreservingError()
            return .failure(.cancelled)
        } catch {
            await transport.releaseAllPreservingError()
            return .failure(.transportFailure(error.localizedDescription))
        }
    }
}
