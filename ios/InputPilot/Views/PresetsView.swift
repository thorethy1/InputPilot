import SwiftData
import SwiftUI

enum PresetIcon {
    static let curated = ["keyboard", "computermouse", "hand.tap", "doc.text", "person.crop.circle", "envelope", "globe", "lock",
                          "key", "bolt", "flag", "star", "folder", "tray.full",
                          "terminal", "gamecontroller", "music.note", "clock"]

    static let labels: [String: String] = [
        "keyboard": "Keyboard",
        "computermouse": "Mouse",
        "hand.tap": "Click",
        "doc.text": "Document",
        "person.crop.circle": "Person",
        "envelope": "Mail",
        "globe": "Globe",
        "lock": "Lock",
        "key": "Key",
        "bolt": "Bolt",
        "flag": "Flag",
        "star": "Star",
        "folder": "Folder",
        "tray.full": "Inbox",
        "terminal": "Terminal",
        "gamecontroller": "Game",
        "music.note": "Music",
        "clock": "Clock"
    ]

    static func label(for symbol: String) -> String { labels[symbol] ?? symbol }

    static func tint(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.78, brightness: 0.96)
    }

    static func badge(for preset: HIDPreset) -> (symbol: String, label: String) {
        if preset.shortcut { return ("keyboard", "Key Combo") }
        if preset.script {
            if let steps = try? PresetScript.parse(preset.payload), let first = steps.first {
                if steps.count == 1, case .click = first {
                    return (first.typeBadgeSymbol, "Mouse Click")
                }
                return (first.typeBadgeSymbol, "Script")
            }
            return ("terminal", "Script")
        }
        return ("textformat", "Text")
    }
}

extension PresetScript.Step {
    var typeBadgeSymbol: String {
        switch self {
        case .text: "textformat"
        case .key: "keyboard"
        case .click: "computermouse"
        case .delay: "clock"
        case .secret: "key"
        }
    }
}

@MainActor @Observable final class PresetsViewModel {
    enum RunState: Equatable {
        case idle
        case running
        case completed
        case failed(String)
    }

    @ObservationIgnored private var manager: HIDConnectionManager?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var execution: Task<Void, Never>?
    private var activeToken: UInt64?
    private(set) var remoteActive = false
    private(set) var runningPresetID: UUID?
    private(set) var completedPresetID: UUID?
    private(set) var failedPresetID: UUID?
    private(set) var lastError: String?

    var isBusy: Bool { runningPresetID != nil || remoteActive }

    static func token(for id: UUID) -> UInt64 {
        UInt64(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16), radix: 16) ?? 1
    }

    static func parseIssue(for script: String) -> (line: Int, reason: String)? {
        do {
            _ = try PresetScript.parse(script)
            return nil
        } catch let error as PresetScript.ParseError {
            return (error.line, error.reason)
        } catch {
            return (0, error.localizedDescription)
        }
    }

    func bind(manager: HIDConnectionManager, context: ModelContext) {
        if self.manager == nil { self.manager = manager }
        if self.modelContext == nil { self.modelContext = context }
    }

    func state(for id: UUID) -> RunState {
        if runningPresetID == id { return .running }
        if completedPresetID == id { return .completed }
        if failedPresetID == id, let lastError { return .failed(lastError) }
        return .idle
    }

    func run(_ preset: HIDPreset, layoutName: String) {
        guard execution == nil, !isBusy, let manager else { return }
        runningPresetID = preset.id
        remoteActive = true
        let token = Self.token(for: preset.id)
        activeToken = token
        failedPresetID = nil
        lastError = nil
        completedPresetID = nil
        let layout = KeyboardLayout(rawValue: layoutName) ?? .german
        let delay = max(0, preset.typingDelayMs)
        var steps: [PresetScript.Step]
        do {
            if preset.shortcut { steps = [.key(preset.payload)] }
            else if preset.script { steps = try PresetScript.parse(preset.payload) }
            else { steps = [.text(preset.payload)] }
            for step in steps { if case let .text(text) = step { _ = try layout.strokes(for: text) } }
            if preset.enterAfter { steps.append(.key("enter")) }
        } catch {
            manager.lastError = error.localizedDescription
            execution = nil
            runningPresetID = nil
            remoteActive = false
            activeToken = nil
            failedPresetID = preset.id
            lastError = error.localizedDescription
            return
        }
        let modelContext = modelContext
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        execution = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ActionExecutor().run(steps: steps, layout: layout, typingDelayMs: delay, token: token, transport: manager, secretResolver: { name in
                guard let modelContext else { throw SecretStoreError.notFound(name) }
                return try SecretStore(context: modelContext).value(forName: name)
            })
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                await self.monitor(presetID: preset.id, token: token, manager: manager)
            case .failure(let error):
                self.execution = nil
                self.remoteActive = false
                self.activeToken = nil
                switch error {
                case .cancelled:
                    self.runningPresetID = nil
                case .secretMissing, .unsupportedCharacter:
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    self.failedPresetID = preset.id
                    self.lastError = error.errorDescription
                    self.runningPresetID = nil
                case .transportFailure(let reason):
                    let detail = manager.lastError ?? reason
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.failedPresetID = preset.id
                    self.lastError = detail
                    self.runningPresetID = nil
                }
            }
        }
    }

    func stop() {
        execution?.cancel()
        execution = nil
        let token = activeToken ?? 0
        guard let manager else {
            runningPresetID = nil
            remoteActive = false
            activeToken = nil
            return
        }
        Task { @MainActor [weak self] in
            let stopped = await manager.abortPreset(token: token)
            guard let self else { return }
            if !stopped { self.lastError = manager.lastError ?? "The device did not stop the preset." }
            self.runningPresetID = nil
            self.remoteActive = false
            self.activeToken = nil
        }
    }

    func refreshRemoteState(presets: [HIDPreset]) async {
        guard execution == nil, let manager else { return }
        var status: DevicePresetStatus?
        for _ in 0 ..< 20 where execution == nil {
            status = await manager.presetStatus()
            if status != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard execution == nil, let status else { return }
        remoteActive = status.isActive
        activeToken = status.isActive ? status.token : nil
        let matchedID = status.isActive
            ? presets.first(where: { Self.token(for: $0.id) == status.token })?.id
            : nil
        runningPresetID = matchedID
        if let matchedID, status.isActive {
            execution = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.monitor(presetID: matchedID, token: status.token, manager: manager)
            }
        } else if status.isActive {
            execution = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.monitorUnknown(token: status.token, manager: manager)
            }
        }
    }

    private func monitorUnknown(token: UInt64, manager: HIDConnectionManager) async {
        while !Task.isCancelled {
            if let status = await manager.presetStatus(), status.token == token, !status.isActive {
                remoteActive = false
                activeToken = nil
                execution = nil
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func monitor(presetID: UUID, token: UInt64, manager: HIDConnectionManager) async {
        while !Task.isCancelled {
            if let status = await manager.presetStatus(), status.token == token {
                switch status.phase {
                case .uploading, .running:
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                case .completed:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    completedPresetID = presetID
                    runningPresetID = nil
                    remoteActive = false
                    activeToken = nil
                    execution = nil
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard let self, self.completedPresetID == presetID else { return }
                        self.completedPresetID = nil
                    }
                    return
                case .cancelled, .idle:
                    runningPresetID = nil
                    remoteActive = false
                    activeToken = nil
                    execution = nil
                    return
                case .failed:
                    lastError = "The preset failed while running on the device."
                    failedPresetID = presetID
                    runningPresetID = nil
                    remoteActive = false
                    activeToken = nil
                    execution = nil
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func dismissError() {
        lastError = nil
        failedPresetID = nil
    }
}

enum PresetEditorMode: Identifiable {
    case create
    case edit(HIDPreset)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let preset): "edit-\(preset.id.uuidString)"
        }
    }
}

struct PresetsView: View {
    @ObservedObject var manager: HIDConnectionManager
    @Environment(\.modelContext) private var context
    @Query(sort: \HIDPreset.order) private var presets: [HIDPreset]
    @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    @State private var model = PresetsViewModel()
    @State private var editorMode: PresetEditorMode?
    @State private var deleteTarget: HIDPreset?
    @State private var isReordering = false
    @State private var sortFavoritesFirst = true

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: AppTheme.Spacing.standard),
         GridItem(.flexible(), spacing: AppTheme.Spacing.standard)]
    }

    private var sortedPresets: [HIDPreset] {
        sortFavoritesFirst
            ? presets.sorted { ($0.favorite != $1.favorite) ? $0.favorite : ($0.order, $0.name) < ($1.order, $1.name) }
            : presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if presets.isEmpty {
                ContentUnavailableView {
                    Label("No Presets", systemImage: "square.grid.2x2")
                } description: {
                    Text("Save text, key combinations or scripts to reuse them with one tap.")
                } actions: {
                    Button("New Preset") { editorMode = .create }
                        .buttonStyle(.borderedProminent)
                }
            } else if isReordering {
                reorderList
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.standard) {
                        ForEach(sortedPresets) { preset in
                            tile(preset)
                        }
                    }
                    .padding(AppTheme.Spacing.standard)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.lastError {
                Button {
                    model.dismissError()
                } label: {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppColors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Spacing.standard)
                        .background(AppColors.error.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AppTheme.Spacing.standard)
                .padding(.bottom, AppTheme.Spacing.compact)
            }
        }
        .toolbar {
            if model.isBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { model.stop() } label: {
                        Label("Stop Preset", systemImage: "stop.circle.fill")
                    }
                    .tint(AppColors.error)
                    .accessibilityHint("Stops the preset currently running on the InputPilot device")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorMode = .create
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        withAnimation { isReordering.toggle() }
                    } label: {
                        Label(isReordering ? "Done Reordering" : "Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    Picker("Sort", selection: $sortFavoritesFirst) {
                        Text("Favorites First").tag(true)
                        Text("Name").tag(false)
                    }
                    if model.isBusy {
                        Button(role: .destructive) {
                            model.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            PresetEditorSheet(mode: mode, nextOrder: (presets.map(\.order).max() ?? -1) + 1)
        }
        .confirmationDialog(
            "Delete ‘\(deleteTarget?.name ?? "")’?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete Preset", role: .destructive) { context.delete(target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The preset is removed from this device.")
        }
        .onAppear {
            model.bind(manager: manager, context: context)
            Task { await model.refreshRemoteState(presets: presets) }
        }
    }

    private var reorderList: some View {
        List {
            ForEach(presets) { preset in
                HStack {
                    Image(systemName: preset.icon)
                        .foregroundStyle(PresetIcon.tint(for: preset.name))
                    Text(preset.name)
                    Spacer()
                    Image(systemName: PresetIcon.badge(for: preset).symbol)
                        .foregroundStyle(.secondary)
                }
            }
            .onMove { source, destination in
                var ordered = presets
                ordered.move(fromOffsets: source, toOffset: destination)
                for (index, item) in ordered.enumerated() { item.order = index }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func tile(_ preset: HIDPreset) -> some View {
        let state = model.state(for: preset.id)
        let tint = PresetIcon.tint(for: preset.name)
        let badge = PresetIcon.badge(for: preset)
        return Button {
            model.run(preset, layoutName: layoutName)
        } label: {
            PresetTileContent(preset: preset, tint: tint, badgeSymbol: badge.symbol, badgeLabel: badge.label, state: state)
        }
        .buttonStyle(PresetTileButtonStyle(reduceMotion: reduceMotion))
        .disabled(model.isBusy)
        .opacity(state == .running ? 1 : (model.isBusy ? 0.55 : 1))
        .contextMenu {
            Button {
                model.run(preset, layoutName: layoutName)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            Button {
                editorMode = .edit(preset)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                duplicate(preset)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                preset.favorite.toggle()
            } label: {
                Label(preset.favorite ? "Unfavorite" : "Favorite", systemImage: preset.favorite ? "star.slash" : "star")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = preset
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
        .accessibilityLabel(preset.name)
        .accessibilityValue(accessibilityValue(for: state))
        .accessibilityHint("Runs preset")
    }

    private func duplicate(_ preset: HIDPreset) {
        let copy = HIDPreset(
            name: preset.name + " Copy",
            payload: preset.payload,
            shortcut: preset.shortcut,
            favorite: false,
            order: (presets.map(\.order).max() ?? -1) + 1,
            enterAfter: preset.enterAfter,
            typingDelayMs: preset.typingDelayMs,
            script: preset.script,
            icon: preset.icon
        )
        context.insert(copy)
    }

    private func accessibilityValue(for state: PresetsViewModel.RunState) -> String {
        switch state {
        case .running: "Running"
        case .failed: "Failed"
        case .completed: "Completed"
        case .idle: ""
        }
    }

    private var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}

private struct PresetTileContent: View {
    let preset: HIDPreset
    let tint: Color
    let badgeSymbol: String
    let badgeLabel: String
    let state: PresetsViewModel.RunState

    var body: some View {
        // Anchor the rectangular tile on a content-independent view. Sizing the
        // ZStack directly lets LazyVGrid estimate unstable row heights, which
        // made tiles overlap and rows at the end of the grid drop out.
        Color.clear
            .aspectRatio(1.45, contentMode: .fit)
            .overlay {
                ZStack {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.25), tint.opacity(0.11)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if #available(iOS 26.0, *) {
                        shape
                            .fill(.clear)
                            .glassEffect(.regular.tint(tint.opacity(0.16)).interactive(), in: shape)
                    } else {
                        shape
                            .strokeBorder(tint.opacity(0.36), lineWidth: 1)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                        HStack(alignment: .top) {
                            Image(systemName: preset.icon)
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(tint)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 0)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                            if preset.favorite {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(tint)
                                    .accessibilityLabel("Favorite")
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: badgeSymbol)
                                .font(.caption2)
                            Text(badgeLabel)
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(AppTheme.Spacing.standard)
                    stateOverlay
                }
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            ZStack {
                Color.black.opacity(0.25)
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        case .completed:
            ZStack {
                Color.black.opacity(0.25)
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.25)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct PresetTileButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PresetEditorSheet: View {
    let mode: PresetEditorMode
    let nextOrder: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "keyboard"
    @State private var type: PresetType = .text
    @State private var mouseButton = MouseButton.left
    @State private var payload = ""
    @State private var favorite = false
    @State private var enterAfter = false
    @State private var typingDelayMs = 0
    @State private var parseIssue: (line: Int, reason: String)?
    @State private var deleteTarget: HIDPreset?

    enum PresetType: String, CaseIterable, Identifiable {
        case text = "Text"
        case shortcut = "Key Combo"
        case click = "Mouse Click"
        case script = "Script"
        var id: String { rawValue }
    }

    private var editingPreset: HIDPreset? {
        if case let .edit(preset) = mode { return preset }
        return nil
    }

    private var isPayloadInvalid: Bool { parseIssue != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isPayloadInvalid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Icon", selection: $icon) {
                        ForEach(PresetIcon.curated, id: \.self) { symbol in
                            Label(PresetIcon.label(for: symbol), systemImage: symbol).tag(symbol)
                        }
                    }
                }
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(PresetType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Type")
                }
                Section {
                    if type == .click {
                        Picker("Mouse button", selection: $mouseButton) {
                            ForEach(MouseButton.allCases, id: \.rawValue) { button in
                                Text(button.displayName).tag(button)
                            }
                        }
                    } else {
                        TextField(payloadPrompt, text: $payload, axis: .vertical)
                            .font(type == .script ? .body.monospaced() : .body)
                            .lineLimit(4...10)
                            .textInputAutocapitalization(type == .script ? .never : nil)
                            .autocorrectionDisabled(type == .script)
                        if let parseIssue {
                            Text(parseIssue.line > 0 ? "Line \(parseIssue.line): \(parseIssue.reason)" : parseIssue.reason)
                                .font(.caption)
                                .foregroundStyle(AppColors.error)
                        }
                    }
                } header: {
                    Text(payloadHeader)
                } footer: {
                    if type == .script {
                        Text("One action per line. Bracketed lines are commands: [TAB], [ENTER], [CTRL+A], [CLICK LEFT], [SECRET name], [DELAY 500]. Everything else is typed as text; # starts a comment.")
                    }
                }
                if type == .script {
                    Section("Secrets") {
                        SecretInsertList(payload: $payload)
                    }
                }
                Section {
                    Toggle("Favorite", isOn: $favorite)
                    Toggle("Enter after", isOn: $enterAfter)
                        .disabled(type == .shortcut || type == .click)
                    Picker("Typing speed", selection: $typingDelayMs) {
                        ForEach([0, 10, 25, 50, 100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) }
                    }
                    .disabled(type == .shortcut || type == .click)
                } header: {
                    Text("Options")
                }
                if editingPreset != nil {
                    Section {
                        Button(role: .destructive) {
                            deleteTarget = editingPreset
                        } label: {
                            Label("Delete Preset", systemImage: "trash")
                                .foregroundStyle(AppColors.destructive)
                        }
                    }
                }
            }
            .navigationTitle(editingPreset == nil ? "New Preset" : "Edit Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .onChange(of: payload) { _, newValue in
                validate(newValue)
            }
            .onChange(of: type) { _, _ in
                validate(payload)
            }
            .confirmationDialog(
                "Delete this preset?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { target in
                Button("Delete Preset", role: .destructive) {
                    context.delete(target)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var payloadHeader: String {
        switch type {
        case .text: "Text"
        case .shortcut: "Key Combo (e.g. ctrl+alt+t)"
        case .click: "Click"
        case .script: "Script"
        }
    }

    private var payloadPrompt: String {
        switch type {
        case .text: "Text to type"
        case .shortcut: "enter"
        case .click: ""
        case .script: "[ENTER]\n[SECRET work-password]\n[DELAY 500]\nplain text"
        }
    }

    private func load() {
        guard let preset = editingPreset else { return }
        name = preset.name
        icon = PresetIcon.curated.contains(preset.icon) ? preset.icon : "keyboard"
        payload = preset.payload
        favorite = preset.favorite
        enterAfter = preset.enterAfter
        typingDelayMs = preset.typingDelayMs
        if preset.shortcut {
            type = .shortcut
        } else if preset.script,
                  let steps = try? PresetScript.parse(preset.payload),
                  steps.count == 1,
                  case let .click(button) = steps[0] {
            type = .click
            mouseButton = button
        } else {
            type = preset.script ? .script : .text
        }
        validate(payload)
    }

    private func validate(_ payload: String) {
        switch type {
        case .script:
            parseIssue = PresetsViewModel.parseIssue(for: payload)
        case .shortcut:
            let trimmed = payload.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                parseIssue = (0, "Enter a key like ENTER or a combination like CTRL+A.")
            } else if AppIntentSupport.keyComboSteps(trimmed) == nil {
                parseIssue = (0, "Use a single key or key combination like ENTER or CTRL+A.")
            } else {
                parseIssue = nil
            }
        case .text, .click:
            parseIssue = nil
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let storedPayload = type == .click ? "[CLICK \(mouseButton.displayName.uppercased())]" : payload
        if let preset = editingPreset {
            preset.name = trimmedName
            preset.icon = icon
            preset.payload = storedPayload
            preset.shortcut = type == .shortcut
            preset.script = type == .script || type == .click
            preset.favorite = favorite
            preset.enterAfter = enterAfter && type != .shortcut && type != .click
            preset.typingDelayMs = type == .shortcut || type == .click ? 0 : typingDelayMs
        } else {
            let preset = HIDPreset(
                name: trimmedName,
                payload: storedPayload,
                shortcut: type == .shortcut,
                favorite: favorite,
                order: nextOrder,
                enterAfter: enterAfter && type != .shortcut && type != .click,
                typingDelayMs: type == .shortcut || type == .click ? 0 : typingDelayMs,
                script: type == .script || type == .click,
                icon: icon
            )
            context.insert(preset)
        }
        dismiss()
    }
}

private struct SecretInsertList: View {
    @Binding var payload: String
    @Query(sort: \StoredSecret.name) private var secrets: [StoredSecret]
    @State private var showSecretsManager = false

    var body: some View {
        if secrets.isEmpty {
            Button {
                showSecretsManager = true
            } label: {
                Label("No secrets yet — create one", systemImage: "key")
            }
            .sheet(isPresented: $showSecretsManager) {
                NavigationStack { SecretsView() }
            }
        } else {
            ForEach(secrets) { secret in
                Button {
                    let prefix = payload.isEmpty || payload.hasSuffix("\n") ? "" : "\n"
                    payload += prefix + "[SECRET \(secret.name)]"
                } label: {
                    Label("Insert [SECRET \(secret.name)]", systemImage: "key")
                }
            }
        }
    }
}
