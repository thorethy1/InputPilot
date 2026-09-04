import AppIntents
import SwiftData
import SwiftUI

struct InputPilotPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Preset")
    static let defaultQuery = PresetEntityQuery()

    var id: UUID
    var name: String
    var icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }

    init(id: UUID, name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}

struct PresetEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [InputPilotPresetEntity] {
        await MainActor.run {
            let context = AppIntentSupport.container.mainContext
            let presets = (try? context.fetch(FetchDescriptor<HIDPreset>())) ?? []
            return presets.filter { identifiers.contains($0.id) }
                .map { InputPilotPresetEntity(id: $0.id, name: $0.name, icon: $0.icon) }
        }
    }

    func suggestedEntities() async throws -> [InputPilotPresetEntity] {
        await MainActor.run { allPresets() }
    }

    func defaultResult() async throws -> InputPilotPresetEntity? {
        await MainActor.run { allPresets().first }
    }

    @MainActor private func allPresets() -> [InputPilotPresetEntity] {
        let context = AppIntentSupport.container.mainContext
        let presets = (try? context.fetch(FetchDescriptor<HIDPreset>(sortBy: [SortDescriptor(\.order)]))) ?? []
        return presets.map { InputPilotPresetEntity(id: $0.id, name: $0.name, icon: $0.icon) }
    }
}

struct InputPilotDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Device")
    static let defaultQuery = DeviceEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct DeviceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [InputPilotDeviceEntity] {
        await MainActor.run {
            let context = AppIntentSupport.container.mainContext
            let devices = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
            return devices.filter { identifiers.contains($0.deviceId) }
                .map { InputPilotDeviceEntity(id: $0.deviceId, name: $0.displayName) }
        }
    }

    func suggestedEntities() async throws -> [InputPilotDeviceEntity] {
        await MainActor.run { allDevices() }
    }

    func defaultResult() async throws -> InputPilotDeviceEntity? {
        await MainActor.run { allDevices().first }
    }

    @MainActor private func allDevices() -> [InputPilotDeviceEntity] {
        let context = AppIntentSupport.container.mainContext
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        return devices.map { InputPilotDeviceEntity(id: $0.deviceId, name: $0.displayName) }
    }
}

struct RunPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Preset"
    static let description = IntentDescription("Runs an InputPilot preset on the active device.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset") var preset: InputPilotPresetEntity
    @Parameter(title: "Device") var device: InputPilotDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$preset) on \(\.$device)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppIntentSupport.container.mainContext
        let presets = (try? context.fetch(FetchDescriptor<HIDPreset>())) ?? []
        guard let model = presets.first(where: { $0.id == preset.id }) else {
            return .result(dialog: IntentDialog(stringLiteral: "This preset is no longer available."))
        }
        let storedDevice: StoredDevice?
        if let device {
            let devices = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
            storedDevice = devices.first { $0.deviceId == device.id }
        } else {
            storedDevice = AppIntentSupport.activeDevice(context: context)
        }
        guard let storedDevice else {
            return .result(dialog: IntentDialog(stringLiteral: "No InputPilot device is saved yet. Add one in the app first."))
        }
        let outcome = await AppIntentSupport.run(preset: model, device: storedDevice, context: context)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct ConnectDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Device"
    static let description = IntentDescription("Connects an InputPilot device and reports the connection state.")
    static let openAppWhenRun = false

    @Parameter(title: "Device") var device: InputPilotDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Connect \(\.$device)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppIntentSupport.container.mainContext
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
        guard let model = devices.first(where: { $0.deviceId == device.id }) else {
            return .result(dialog: IntentDialog(stringLiteral: "This device is no longer available."))
        }
        let summary = await AppIntentSupport.connectSummary(for: model)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct CheckDeviceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Device Status"
    static let description = IntentDescription("Reports whether an InputPilot device is connected, connecting or offline.")
    static let openAppWhenRun = false

    @Parameter(title: "Device") var device: InputPilotDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check status of \(\.$device)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppIntentSupport.container.mainContext
        let devices = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
        let storedDevice: StoredDevice?
        if let device {
            storedDevice = devices.first { $0.deviceId == device.id }
        } else {
            storedDevice = AppIntentSupport.activeDevice(context: context)
        }
        guard let storedDevice else {
            return .result(dialog: IntentDialog(stringLiteral: "No InputPilot device is saved yet. Add one in the app first."))
        }
        let summary = await AppIntentSupport.connectSummary(for: storedDevice)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SendKeyboardShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Keyboard Shortcut"
    static let description = IntentDescription("Sends a keyboard shortcut like ENTER or CTRL+A to the active InputPilot device.")
    static let openAppWhenRun = false

    @Parameter(title: "Key Combo", default: "enter") var keyCombo: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let steps = AppIntentSupport.keyComboSteps(keyCombo) else {
            return .result(dialog: IntentDialog(stringLiteral: "Use a key like ENTER or a combination like CTRL+A."))
        }
        let context = AppIntentSupport.container.mainContext
        guard let device = AppIntentSupport.activeDevice(context: context) else {
            return .result(dialog: IntentDialog(stringLiteral: "No InputPilot device is saved yet. Add one in the app first."))
        }
        let outcome = await AppIntentSupport.run(steps: steps, typingDelayMs: 0, device: device, context: context)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text"
    static let description = IntentDescription("Types text on the computer connected to the active InputPilot device.")
    static let openAppWhenRun = false

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Typing Delay (ms)") var typingDelayMs: Int?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppIntentSupport.container.mainContext
        guard let device = AppIntentSupport.activeDevice(context: context) else {
            return .result(dialog: IntentDialog(stringLiteral: "No InputPilot device is saved yet. Add one in the app first."))
        }
        let outcome = await AppIntentSupport.run(
            steps: [.text(text)],
            typingDelayMs: max(0, typingDelayMs ?? 0),
            device: device,
            context: context
        )
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}
