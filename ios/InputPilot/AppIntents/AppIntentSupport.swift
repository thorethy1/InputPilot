import Foundation
import SwiftData

struct PresetRunOutcome: Equatable, Sendable {
    let success: Bool
    let message: String
}

@MainActor enum AppIntentSupport {
    static var container: ModelContainer { AppModelContainer.shared }

    static func activeDevice(context: ModelContext) -> StoredDevice? {
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        guard !devices.isEmpty else { return nil }
        let savedID = UserDefaults.standard.string(forKey: "selectedDeviceId") ?? ""
        let resolved = ActiveDeviceSelection.resolve(savedID: savedID, availableIDs: devices.map(\.deviceId))
        return devices.first { $0.deviceId == resolved }
    }

    static func steps(for preset: HIDPreset) throws -> [PresetScript.Step] {
        var steps: [PresetScript.Step]
        if preset.shortcut { steps = [.key(preset.payload)] }
        else if preset.script { steps = try PresetScript.parse(preset.payload) }
        else { steps = [.text(preset.payload)] }
        if preset.enterAfter { steps.append(.key("enter")) }
        return steps
    }

    static func keyComboSteps(_ combo: String) -> [PresetScript.Step]? {
        guard let steps = try? PresetScript.parse(combo), steps.count == 1, case .key = steps[0] else { return nil }
        return steps
    }

    static func run(preset: HIDPreset, device: StoredDevice, context: ModelContext) async -> PresetRunOutcome {
        let manager = HIDConnectionManager(device: device)
        await manager.connect()
        let outcome = await run(preset: preset, manager: manager, context: context)
        await manager.disconnect()
        return outcome
    }

    static func run(steps: [PresetScript.Step],
                    typingDelayMs: Int,
                    device: StoredDevice,
                    context: ModelContext) async -> PresetRunOutcome {
        let manager = HIDConnectionManager(device: device)
        await manager.connect()
        guard await manager.waitUntilReady() else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        let outcome = await execute(steps: steps, typingDelayMs: typingDelayMs, transport: manager, context: context)
        await manager.disconnect()
        return outcome
    }

    static func run(preset: HIDPreset, manager: HIDConnectionManager, context: ModelContext) async -> PresetRunOutcome {
        guard await manager.waitUntilReady() else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        let steps: [PresetScript.Step]
        do {
            steps = try AppIntentSupport.steps(for: preset)
        } catch {
            return PresetRunOutcome(success: false, message: error.localizedDescription)
        }
        return await execute(steps: steps, typingDelayMs: max(0, preset.typingDelayMs), transport: manager, context: context)
    }

    static func execute(steps: [PresetScript.Step],
                        typingDelayMs: Int,
                        transport: HIDActionTransport,
                        context: ModelContext) async -> PresetRunOutcome {
        let layout = KeyboardLayout(rawValue: UserDefaults.standard.string(forKey: "keyboardLayout") ?? "") ?? .german
        let result = await ActionExecutor().run(
            steps: steps,
            layout: layout,
            typingDelayMs: typingDelayMs,
            transport: transport,
            secretResolver: { name in try SecretStore(context: context).value(forName: name) }
        )
        return outcome(from: result)
    }

    static func connectSummary(for device: StoredDevice) async -> String {
        let manager = HIDConnectionManager(device: device)
        await manager.connect()
        // connect() only starts the transports; give the connection a bounded
        // chance to finish before reporting a summary.
        _ = await manager.waitUntilReady()
        let summary = manager.connectionSummary
        await manager.disconnect()
        return summary
    }

    static func outcome(from result: Result<Void, ActionExecutionError>) -> PresetRunOutcome {
        switch result {
        case .success:
            PresetRunOutcome(success: true, message: "Done.")
        case .failure(let error):
            PresetRunOutcome(success: false, message: error.errorDescription ?? "The action could not run.")
        }
    }
}
