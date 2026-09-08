import Foundation
import SwiftData
import Combine

// Keep the original offset/event encoding readable. Secret references are an
// optional addition inside the existing Data attribute, not a SwiftData change.
struct RecordedEvent: Codable, Equatable {
    var offset: TimeInterval
    var event: HIDEvent
    var secretID: UUID? = nil

    var title: String {
        if secretID != nil { return "Secret" }
        switch event {
        case .mouseMove: return "Move pointer"
        case .scroll: return "Scroll"
        case let .mouseDown(button): return "Hold \(button) button"
        case let .mouseUp(button): return "Release \(button) button"
        case let .click(button): return "Click \(button) button"
        case .typeText: return "Type text"
        case let .key(key), let .keyCombo(key): return key
        case .keyboardReport: return "Keyboard input"
        case .releaseAll: return "Release all input"
        case .ping: return "Pause"
        }
    }

    static func validate(_ events: [Self]) -> Bool {
        var previous = 0.0
        for item in events {
            guard item.offset.isFinite, item.offset >= previous else { return false }
            previous = item.offset
        }
        return !events.isEmpty
    }
}

@Model final class HIDMacro {
    var name: String
    var macroDescription: String = ""
    var encodedEvents: Data
    var createdAt: Date

    init(name: String, description: String = "", events: [RecordedEvent]) {
        self.name = name
        macroDescription = description
        encodedEvents = (try? JSONEncoder().encode(events)) ?? Data()
        createdAt = Date()
    }

    var events: [RecordedEvent] {
        (try? JSONDecoder().decode([RecordedEvent].self, from: encodedEvents)) ?? []
    }
}

@MainActor final class MacroController: ObservableObject {
    enum State: String { case ready = "Ready", waiting = "Starting", running = "Running", cancelling = "Stopping", completed = "Completed", cancelled = "Cancelled", failed = "Failed" }
    @Published private(set) var state: State = .ready
    @Published private(set) var isRecording = false
    @Published var recorded: [RecordedEvent] = []
    @Published private(set) var completedEvents = 0
    @Published private(set) var eventCount = 0
    @Published private(set) var iteration = 0
    @Published private(set) var repeats: Int?
    @Published private(set) var currentName = ""
    @Published private(set) var errorMessage: String?
    private var started = Date()
    private var playback: Task<Void, Never>?

    var isPlaying: Bool { [.waiting, .running, .cancelling].contains(state) }
    var recordingDuration: TimeInterval { isRecording ? Date().timeIntervalSince(started) : 0 }
    var progress: Double {
        guard eventCount > 0 else { return 0 }
        if let repeats {
            return min(1, (Double(max(0, iteration - 1)) + Double(completedEvents) / Double(eventCount)) / Double(repeats))
        }
        return Double(completedEvents) / Double(eventCount)
    }

    func startRecording() {
        guard !isPlaying else { return }
        recorded = []; started = Date(); isRecording = true; state = .ready
    }

    func capture(_ event: HIDEvent) {
        guard isRecording, !isPlaying else { return }
        let now = Date().timeIntervalSince(started)
        if case let .mouseMove(x, y) = event, let last = recorded.last,
           now - last.offset <= 0.02, case let .mouseMove(lastX, lastY) = last.event {
            recorded[recorded.count - 1] = RecordedEvent(offset: now, event: .mouseMove(Int16(clamping: Int(lastX) + Int(x)), Int16(clamping: Int(lastY) + Int(y))))
        } else { recorded.append(RecordedEvent(offset: now, event: event)) }
    }

    func stopRecording() { isRecording = false }

    func play(_ macro: HIDMacro, speed: Double, repeats: Int?, delay: Double,
              manager: HIDActionTransport, layout: KeyboardLayout = .german,
              secretResolver: @escaping (UUID) throws -> String = { _ in throw ActionExecutionError.secretMissing("Unavailable secret") }) {
        guard !isPlaying, !isRecording else { return }
        let events = macro.events // Snapshot: edits cannot change a running sequence.
        currentName = macro.name
        errorMessage = nil
        guard RecordedEvent.validate(events), speed.isFinite, speed > 0,
              delay.isFinite, delay >= 0, repeats == nil || repeats! > 0 else {
            errorMessage = "This macro is empty or contains invalid timing. Edit it before running."
            state = .failed
            return
        }
        eventCount = events.count; completedEvents = 0; iteration = 0; self.repeats = repeats
        state = .waiting
        playback = Task {
            var ownsSession = false
            var finalState: State = .completed
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                guard manager.beginOrderedSession(lowLatency: false) else {
                    throw ActionExecutionError.transportFailure("The device is not connected. Reconnect and try again.")
                }
                ownsSession = true
                state = .running
                while repeats == nil || iteration < repeats! {
                    try Task.checkCancellation()
                    iteration += 1; completedEvents = 0
                    var previous = 0.0
                    for item in events {
                        try await Task.sleep(for: .seconds((item.offset - previous) / speed))
                        try Task.checkCancellation()
                        previous = item.offset
                        let sent: Bool
                        if let id = item.secretID {
                            // Never pass Keychain or mapping errors containing data into UI/logs.
                            let value: String
                            do { value = try secretResolver(id) }
                            catch { throw ActionExecutionError.secretMissing("Referenced secret") }
                            do { _ = try layout.strokes(for: value) }
                            catch { throw ActionExecutionError.transportFailure("The secret cannot be typed with the selected keyboard layout.") }
                            sent = await manager.sendText(value, layout: layout, delayMilliseconds: 0)
                        } else if case let .typeText(text) = item.event {
                            sent = await manager.sendText(text, layout: layout, delayMilliseconds: 0)
                        } else {
                            sent = await manager.send(item.event)
                        }
                        try Task.checkCancellation()
                        guard sent else { throw ActionExecutionError.transportFailure("The device stopped accepting input. Reconnect and try again.") }
                        completedEvents += 1
                        // High playback speeds must not overrun the firmware HID queue.
                        try await Task.sleep(for: .milliseconds(8))
                    }
                    // Drain the queue before release-all, which clears queued HID events.
                    try await Task.sleep(for: .milliseconds(200))
                    await manager.releaseAllPreservingError()
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                finalState = .cancelled
            } catch {
                errorMessage = error.localizedDescription
                finalState = .failed
            }
            if ownsSession {
                // Keep the run busy until cleanup ends. A second run cannot be
                // interrupted by a release-all from the previous task.
                await manager.releaseAllPreservingError()
                manager.endOrderedSession()
            }
            state = Task.isCancelled ? .cancelled : finalState
            playback = nil
        }
    }

    func cancel() {
        guard isPlaying, state != .cancelling else { return }
        state = .cancelling
        playback?.cancel()
    }

    func waitForPlayback() async { await playback?.value }
}
