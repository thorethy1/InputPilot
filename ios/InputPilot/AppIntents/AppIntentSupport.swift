import Foundation
import SwiftData

struct PresetRunOutcome: Equatable, Sendable {
    let success: Bool
    let message: String
}

@MainActor enum AppIntentSupport {
    static var container: ModelContainer { AppModelContainer.shared }

    private static var cachedManagers: [String: (manager: HIDConnectionManager, host: String)] = [:]
    private static var executionTail: Task<Void, Never>?

    static func activeDevice(context: ModelContext) -> StoredDevice? {
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        guard !devices.isEmpty else { return nil }
        let savedID = UserDefaults.standard.string(forKey: "selectedDeviceId") ?? ""
        let resolved = ActiveDeviceSelection.resolve(savedID: savedID, availableIDs: devices.map(\.deviceId))
        return devices.first { $0.deviceId == resolved }
    }

    /// Returns one long-lived connection manager per device so back-to-back
    /// Shortcuts reuse an established session instead of reconnecting from
    /// scratch. A changed Wi-Fi endpoint replaces the cached manager.
    static func manager(for device: StoredDevice) -> HIDConnectionManager {
        let key = device.deviceId.lowercased()
        let host = device.staIP ?? device.mdnsHost
        if let cached = cachedManagers[key], cached.host == host { return cached.manager }
        let manager = HIDConnectionManager(device: device)
        cachedManagers[key] = (manager, host)
        return manager
    }

    /// Runs intent work strictly one after another: when a user fires several
    /// App Intents in quick succession, each one waits for the previous
    /// sequence (typing included) to finish before connecting or sending.
    static func serialized(_ work: @MainActor @escaping () async -> PresetRunOutcome) async -> PresetRunOutcome {
        let previous = executionTail
        let task = Task<PresetRunOutcome, Never> { @MainActor [previous] in
            await previous?.value
            return await work()
        }
        executionTail = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
        guard let step = PresetScript.parseKeyCombo(combo) else { return nil }
        return [step]
    }

    static func run(preset: HIDPreset, device: StoredDevice, context: ModelContext, readinessTimeout: TimeInterval = 15) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        let outcome = await run(preset: preset, manager: manager, context: context, readinessTimeout: readinessTimeout)
        // Keep the shared connection warm; follow-up Shortcuts then start on an
        // established session instead of paying the reconnect cost again.
        return outcome
    }

    static func run(steps: [PresetScript.Step],
                    typingDelayMs: Int,
                    device: StoredDevice,
                    context: ModelContext,
                    readinessTimeout: TimeInterval = 15) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        guard await manager.waitUntilReady(timeout: readinessTimeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        let outcome = await execute(steps: steps, typingDelayMs: typingDelayMs, transport: manager, context: context)
        return outcome
    }

    static func run(preset: HIDPreset, manager: HIDConnectionManager, context: ModelContext, readinessTimeout: TimeInterval = 15) async -> PresetRunOutcome {
        guard await manager.waitUntilReady(timeout: readinessTimeout) else {
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
        let manager = manager(for: device)
        await manager.connect()
        // connect() only starts the transports; give the connection a bounded
        // chance to finish before reporting a summary. The shared session stays
        // connected so the next intent does not reconnect from scratch.
        _ = await manager.waitUntilReady()
        return manager.connectionSummary
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
