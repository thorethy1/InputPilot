import XCTest
import SwiftData
@testable import InputPilot

@MainActor private final class MacroTestTransport: HIDActionTransport {
    var ready = true
    var acceptsInput = true
    var events: [HIDEvent] = []
    var texts: [String] = []
    var releases = 0
    var starts = 0
    var ends = 0
    var onSend: (() -> Void)?
    var onRelease: (() -> Void)?
    func beginOrderedSession(lowLatency: Bool) -> Bool { starts += 1; return ready }
    func endOrderedSession() { ends += 1 }
    func send(_ event: HIDEvent) async -> Bool { events.append(event); onSend?(); return acceptsInput }
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool { texts.append(text); return acceptsInput }
    func releaseAllPreservingError() async { releases += 1; onRelease?() }
}

final class MacroControllerTests: XCTestCase {
    func testLegacyEventDataDecodesWithoutSecretReference() throws {
        let data = Data(#"[{"offset":0.25,"event":{"mouseMove":{"_0":12,"_1":-3}}}]"#.utf8)
        let events = try JSONDecoder().decode([RecordedEvent].self, from: data)
        XCTAssertEqual(events, [RecordedEvent(offset: 0.25, event: .mouseMove(12, -3))])
    }

    func testTimelineRejectsEmptyReversedAndNonFiniteOffsets() {
        XCTAssertFalse(RecordedEvent.validate([]))
        XCTAssertFalse(RecordedEvent.validate([.init(offset: -1, event: .ping)]))
        XCTAssertFalse(RecordedEvent.validate([.init(offset: .infinity, event: .ping)]))
        XCTAssertFalse(RecordedEvent.validate([.init(offset: 2, event: .ping), .init(offset: 1, event: .ping)]))
        XCTAssertTrue(RecordedEvent.validate([.init(offset: 0, event: .ping), .init(offset: 0, event: .ping)]))
    }

    @MainActor func testRepeatsReleaseInputAndReportCompletedProgress() async {
        let controller = MacroController(), transport = MacroTestTransport()
        let macro = HIDMacro(name: "Drag", events: [.init(offset: 0, event: .mouseDown(.left))])
        controller.play(macro, speed: 2, repeats: 2, delay: 0, manager: transport)
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.iteration, 2)
        XCTAssertEqual(controller.progress, 1)
        XCTAssertEqual(transport.events, [.mouseDown(.left), .mouseDown(.left)])
        XCTAssertGreaterThanOrEqual(transport.releases, 2)
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.ends, 1)
    }

    @MainActor func testCancellationDuringDelaySendsNothing() async {
        let controller = MacroController(), transport = MacroTestTransport()
        controller.play(HIDMacro(name: "Delayed", events: [.init(offset: 0, event: .click(.left))]), speed: 1, repeats: 1, delay: 60, manager: transport)
        controller.cancel()
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertTrue(transport.events.isEmpty)
        XCTAssertEqual(transport.starts, 0)
    }

    @MainActor func testCancellationOfHeldInputReleasesBeforeNewRunIsAllowed() async {
        let controller = MacroController(), transport = MacroTestTransport()
        let macro = HIDMacro(name: "Held input", events: [.init(offset: 0, event: .mouseDown(.left)), .init(offset: 60, event: .mouseUp(.left))])
        transport.onSend = { controller.cancel() }
        transport.onRelease = {
            XCTAssertTrue(controller.isPlaying)
            controller.play(macro, speed: 1, repeats: 1, delay: 0, manager: transport)
        }
        controller.play(macro, speed: 1, repeats: 1, delay: 0, manager: transport)
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertEqual(transport.events, [.mouseDown(.left)])
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.releases, 1)
        XCTAssertEqual(transport.ends, 1)
    }

    @MainActor func testFailureReleasesInputAndStopsSequence() async {
        let controller = MacroController(), transport = MacroTestTransport()
        transport.acceptsInput = false
        controller.play(HIDMacro(name: "Failure", events: [.init(offset: 0, event: .mouseDown(.left)), .init(offset: 1, event: .click(.right))]), speed: 1, repeats: 1, delay: 0, manager: transport)
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(transport.events.count, 1)
        XCTAssertEqual(transport.releases, 1)
        XCTAssertEqual(transport.ends, 1)
    }

    @MainActor func testUnavailableTransportFailsWithoutExecuting() async {
        let controller = MacroController(), transport = MacroTestTransport()
        transport.ready = false
        controller.play(HIDMacro(name: "Offline", events: [.init(offset: 0, event: .ping)]), speed: 1, repeats: 1, delay: 0, manager: transport)
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(transport.events.isEmpty)
        XCTAssertEqual(transport.ends, 0)
    }

    @MainActor func testSecretReferencesAreResolvedAtRunTimeAndNeverRecorded() async throws {
        let id = UUID(), controller = MacroController(), transport = MacroTestTransport()
        let macro = HIDMacro(name: "Secret", events: [.init(offset: 0, event: .ping, secretID: id)])
        controller.play(macro, speed: 1, repeats: 1, delay: 0, manager: transport, layout: .us, secretResolver: { resolved in
            XCTAssertEqual(resolved, id)
            return "private-value"
        })
        controller.startRecording() // Must be ignored while playing.
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(transport.texts, ["private-value"])
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.recorded.isEmpty)
        XCTAssertFalse(String(decoding: macro.encodedEvents, as: UTF8.self).contains("private-value"))
        XCTAssertEqual(try JSONDecoder().decode([RecordedEvent].self, from: macro.encodedEvents).first?.secretID, id)
    }

    @MainActor func testMissingSecretFailsSafelyWithoutLeakingResolverError() async {
        let controller = MacroController(), transport = MacroTestTransport()
        controller.play(HIDMacro(name: "Missing", events: [.init(offset: 0, event: .ping, secretID: UUID())]), speed: 1, repeats: 1, delay: 0, manager: transport, secretResolver: { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-value"])
        })
        await controller.waitForPlayback()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertFalse(controller.errorMessage?.contains("private-value") ?? true)
        XCTAssertTrue(transport.texts.isEmpty)
        XCTAssertEqual(transport.releases, 1)
    }

    @MainActor func testDuplicatePlayDoesNotRestartOrReplaceCurrentMacro() async {
        let controller = MacroController(), transport = MacroTestTransport()
        let macro = HIDMacro(name: "First", events: [.init(offset: 0, event: .ping)])
        controller.play(macro, speed: 1, repeats: 1, delay: 60, manager: transport)
        controller.play(HIDMacro(name: "Second", events: macro.events), speed: 1, repeats: 1, delay: 0, manager: transport)
        XCTAssertEqual(controller.currentName, "First")
        controller.cancel()
        await controller.waitForPlayback()
    }

    @MainActor func testExistingMacroDataSurvivesStoreReopenAndSecretExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        func writeLegacy() throws {
            let container = try ModelContainer(for: HIDMacro.self, configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let macro = HIDMacro(name: "Existing", description: "Keep this", events: [])
            macro.encodedEvents = Data(#"[{"offset":0,"event":{"ping":{}}}]"#.utf8)
            context.insert(macro)
            try context.save()
        }
        try writeLegacy()
        let container = try ModelContainer(for: HIDMacro.self, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        let macro = try XCTUnwrap(context.fetch(FetchDescriptor<HIDMacro>()).first)
        XCTAssertEqual(macro.name, "Existing")
        XCTAssertEqual(macro.macroDescription, "Keep this")
        XCTAssertEqual(macro.events, [.init(offset: 0, event: .ping)])
        let id = UUID()
        macro.encodedEvents = try JSONEncoder().encode(macro.events + [.init(offset: 1, event: .ping, secretID: id)])
        try context.save()
        XCTAssertEqual(macro.events.last?.secretID, id)
    }
}
