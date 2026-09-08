import Foundation
import SwiftData

struct PresetRunOutcome: Equatable, Sendable {
    let success: Bool
    let message: String
}

@MainActor enum AppIntentSupport {
    static var container: ModelContainer { AppModelContainer.shared }

    private static var cachedManagers: [String: (manager: HIDConnectionManager, host: String)] = [:]
    nonisolated static let readinessTimeout: TimeInterval = 25
    private static var executionTail: Task<PresetRunOutcome, Never>?

    static func activeDevice(context: ModelContext) -> StoredDevice? {
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        guard !devices.isEmpty else { return nil }
        let savedID = UserDefaults.standard.string(forKey: "selectedDeviceId") ?? ""
        let resolved = ActiveDeviceSelection.resolve(savedID: savedID, availableIDs: devices.map(\.deviceId))
        return devices.first { $0.deviceId == resolved }
    }

    static func device(matching entity: InputPilotDeviceEntity?, context: ModelContext) -> StoredDevice? {
        guard let entity else { return activeDevice(context: context) }
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
        return devices.first { $0.deviceId == entity.id }
    }

    static func select(_ device: StoredDevice) -> PresetRunOutcome {
        UserDefaults.standard.set(device.deviceId, forKey: "selectedDeviceId")
        return PresetRunOutcome(success: true, message: "\(device.displayName) is now the active InputPilot device.")
    }

    static func setMouseMove(_ enabled: Bool, for device: StoredDevice,
                             context: ModelContext,
                             timeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        guard await manager.waitUntilReady(timeout: timeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        do {
            try await DeviceRepository(context: context).setJiggle(device, enabled: enabled)
            return PresetRunOutcome(
                success: true,
                message: enabled ? "Periodic mouse movement started on \(device.displayName)." : "Periodic mouse movement stopped on \(device.displayName)."
            )
        } catch {
            return PresetRunOutcome(success: false, message: "Mouse movement could not be updated. Reconnect the device and try again.")
        }
    }

    static func send(_ event: HIDEvent, to device: StoredDevice,
                     timeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        guard await manager.waitUntilReady(timeout: timeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        guard await manager.send(event) else {
            return PresetRunOutcome(success: false, message: manager.lastError ?? "The action could not be delivered.")
        }
        return PresetRunOutcome(success: true, message: "Done on \(device.displayName).")
    }

    /// Returns one long-lived connection manager per device so back-to-back
    /// Shortcuts reuse an established session instead of reconnecting from
    /// scratch. A changed Wi-Fi endpoint replaces the cached manager.
    static func manager(for device: StoredDevice) -> HIDConnectionManager {
        let key = device.deviceId.lowercased()
        let host = DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP).map(\.absoluteString).joined(separator: "|")
        if let cached = cachedManagers[key], cached.host == host {
            cached.manager.mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .automatic
            return cached.manager
        }
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
            _ = await previous?.value
            guard !Task.isCancelled else { return PresetRunOutcome(success: false, message: "The action was cancelled.") }
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

    static func run(preset: HIDPreset, device: StoredDevice, context: ModelContext, readinessTimeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        let outcome = await run(preset: preset, manager: manager, context: context, readinessTimeout: readinessTimeout)
        // Keep the shared connection warm; follow-up Shortcuts then start on an
        // established session instead of paying the reconnect cost again.
        return outcome
    }

    static func run(macro: HIDMacro,
                    speed: Double,
                    repeats: Int,
                    delay: Double,
                    device: StoredDevice,
                    context: ModelContext,
                    readinessTimeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        return await run(
            macro: macro,
            speed: speed,
            repeats: repeats,
            delay: delay,
            manager: manager,
            context: context,
            readinessTimeout: readinessTimeout
        )
    }

    static func run(macro: HIDMacro,
                    speed: Double,
                    repeats: Int,
                    delay: Double,
                    manager: HIDConnectionManager,
                    context: ModelContext,
                    readinessTimeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        guard await manager.waitUntilReady(timeout: readinessTimeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        let controller = MacroController()
        controller.play(
            macro,
            speed: speed,
            repeats: repeats,
            delay: delay,
            manager: manager,
            layout: KeyboardLayout(rawValue: UserDefaults.standard.string(forKey: "keyboardLayout") ?? "") ?? .german,
            secretResolver: { try SecretStore(context: context).value(forID: $0) }
        )
        await withTaskCancellationHandler {
            await controller.waitForPlayback()
        } onCancel: {
            Task { @MainActor in controller.cancel() }
        }
        switch controller.state {
        case .completed:
            return PresetRunOutcome(success: true, message: "\(macro.name) completed.")
        case .cancelled, .cancelling:
            return PresetRunOutcome(success: false, message: "\(macro.name) was cancelled.")
        case .failed:
            return PresetRunOutcome(success: false, message: controller.errorMessage ?? "The macro could not run.")
        case .ready, .waiting, .running:
            return PresetRunOutcome(success: false, message: "The macro did not finish.")
        }
    }

    static func run(steps: [PresetScript.Step],
                    typingDelayMs: Int,
                    device: StoredDevice,
                    context: ModelContext,
                    readinessTimeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        let manager = manager(for: device)
        await manager.connect()
        guard await manager.waitUntilReady(timeout: readinessTimeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        let outcome = await execute(steps: steps, typingDelayMs: typingDelayMs, transport: manager, context: context)
        return outcome
    }

    static func run(preset: HIDPreset, manager: HIDConnectionManager, context: ModelContext, readinessTimeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
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

    static func connectOutcome(for device: StoredDevice) async -> PresetRunOutcome {
        await connectOutcome(manager: manager(for: device))
    }

    static func connectOutcome(manager: HIDConnectionManager,
                               timeout: TimeInterval = AppIntentSupport.readinessTimeout) async -> PresetRunOutcome {
        await manager.connect()
        guard await manager.waitUntilReady(timeout: timeout) else {
            return PresetRunOutcome(success: false, message: "The device did not finish connecting in time (\(manager.connectionSummary)).")
        }
        return PresetRunOutcome(success: true, message: manager.connectionSummary)
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
