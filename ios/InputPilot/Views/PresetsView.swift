import SwiftData
import SwiftUI

enum PresetIcon {
    static let curated = ["keyboard", "doc.text", "person.crop.circle", "envelope", "globe", "lock",
                          "key", "bolt", "flag", "star", "folder", "tray.full",
                          "terminal", "gamecontroller", "music.note", "clock"]

    static func tint(for name: String) -> Color {
        let hash = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.42, brightness: 0.92)
    }
}

extension PresetScript.Step {
    var typeBadgeSymbol: String {
        switch self {
        case .text: "textformat"
        case .key: "keyboard"
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
    private(set) var runningPresetID: UUID?
    private(set) var completedPresetID: UUID?
    private(set) var failedPresetID: UUID?
    private(set) var lastError: String?

    var isBusy: Bool { runningPresetID != nil }

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
        guard execution == nil, let manager else { return }
        runningPresetID = preset.id
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
            failedPresetID = preset.id
            lastError = error.localizedDescription
            return
        }
        let modelContext = modelContext
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        execution = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ActionExecutor().run(steps: steps, layout: layout, typingDelayMs: delay, transport: manager, secretResolver: { name in
                guard let modelContext else { throw SecretStoreError.notFound(name) }
                return try SecretStore(context: modelContext).value(forName: name)
            })
            self.execution = nil
            switch result {
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.completedPresetID = preset.id
                self.runningPresetID = nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, self.completedPresetID == preset.id else { return }
                    self.completedPresetID = nil
                }
            case .failure(let error):
                switch error {
                case .cancelled:
                    self.runningPresetID = nil
                case .secretMissing, .unsupportedCharacter:
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    self.failedPresetID = preset.id
                    self.lastError = error.errorDescription
                    self.runningPresetID = nil
                case .transportFailure(let reason):
                    manager.lastError = reason
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.failedPresetID = preset.id
                    self.lastError = reason
                    self.runningPresetID = nil
                }
            }
        }
    }

    func stop() {
        execution?.cancel()
        execution = nil
        runningPresetID = nil
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
         GridItem(.flexible(), spacing: AppTheme.Spacing.standard),
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
        }
        .onDisappear {
            model.stop()
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
                    Image(systemName: typeBadgeSymbol(for: preset))
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
        return Button {
            model.run(preset, layoutName: layoutName)
        } label: {
            PresetTileContent(preset: preset, tint: tint, state: state)
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

    private func typeBadgeSymbol(for preset: HIDPreset) -> String {
        if preset.shortcut { return "keyboard" }
        if preset.script { return (try? PresetScript.parse(preset.payload).first)?.typeBadgeSymbol ?? "terminal" }
        return "textformat"
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
    let state: PresetsViewModel.RunState

    var body: some View {
        ZStack {
            shape
                .fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if #available(iOS 26.0, *) {
                shape
                    .fill(.clear)
                    .glassEffect(.regular.tint(tint.opacity(0.35)), in: shape)
            } else {
                shape
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                HStack(alignment: .top) {
                    Image(systemName: preset.icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if preset.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer(minLength: 0)
                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: badgeSymbol)
                        .font(.caption2)
                    Text(badgeLabel)
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(AppTheme.Spacing.standard)
            stateOverlay
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
    }

    private var badgeSymbol: String {
        if preset.shortcut { return "keyboard" }
        if preset.script { return (try? PresetScript.parse(preset.payload).first)?.typeBadgeSymbol ?? "terminal" }
        return "textformat"
    }

    private var badgeLabel: String {
        if preset.shortcut { return "Key Combo" }
        if preset.script { return "Script" }
        return "Text"
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
    @State private var payload = ""
    @State private var favorite = false
    @State private var enterAfter = false
    @State private var typingDelayMs = 0
    @State private var parseIssue: (line: Int, reason: String)?
    @State private var deleteTarget: HIDPreset?

    enum PresetType: String, CaseIterable, Identifiable {
        case text = "Text"
        case shortcut = "Key Combo"
        case script = "Script"
        var id: String { rawValue }
    }

    private var editingPreset: HIDPreset? {
        if case let .edit(preset) = mode { return preset }
        return nil
    }

    private var isScriptInvalid: Bool { type == .script && parseIssue != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isScriptInvalid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Icon", selection: $icon) {
                        ForEach(PresetIcon.curated, id: \.self) { symbol in
                            Label(symbol, systemImage: symbol).tag(symbol)
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
                    TextField(payloadPrompt, text: $payload, axis: .vertical)
                        .font(type == .script ? .body.monospaced() : .body)
                        .lineLimit(4...10)
                        .textInputAutocapitalization(type == .script ? .never : nil)
                        .autocorrectionDisabled(type == .script)
                    if type == .script, let parseIssue {
                        Text("Line \(parseIssue.line): \(parseIssue.reason)")
                            .font(.caption)
                            .foregroundStyle(AppColors.error)
                    }
                } header: {
                    Text(payloadHeader)
                } footer: {
                    if type == .script {
                        Text("One action per line: [TAB], [ENTER], [CTRL+A], [DELAY 500], SECRET <name> or plain text.")
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
                        .disabled(type == .shortcut)
                    Picker("Typing speed", selection: $typingDelayMs) {
                        ForEach([0, 10, 25, 50, 100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) }
                    }
                    .disabled(type == .shortcut)
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
        case .script: "Script"
        }
    }

    private var payloadPrompt: String {
        switch type {
        case .text: "Text to type"
        case .shortcut: "enter"
        case .script: "[TAB]\n[SECRET work-password]\n[DELAY 500]"
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
        type = preset.shortcut ? .shortcut : (preset.script ? .script : .text)
        validate(payload)
    }

    private func validate(_ script: String) {
        guard type == .script else {
            parseIssue = nil
            return
        }
        parseIssue = PresetsViewModel.parseIssue(for: script)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if let preset = editingPreset {
            preset.name = trimmedName
            preset.icon = icon
            preset.payload = payload
            preset.shortcut = type == .shortcut
            preset.script = type == .script
            preset.favorite = favorite
            preset.enterAfter = enterAfter && type != .shortcut
            preset.typingDelayMs = type == .shortcut ? 0 : typingDelayMs
        } else {
            let preset = HIDPreset(
                name: trimmedName,
                payload: payload,
                shortcut: type == .shortcut,
                favorite: favorite,
                order: nextOrder,
                enterAfter: enterAfter && type != .shortcut,
                typingDelayMs: type == .shortcut ? 0 : typingDelayMs,
                script: type == .script,
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
                    payload += prefix + "SECRET \(secret.name)"
                } label: {
                    Label("Insert SECRET \(secret.name)", systemImage: "key")
                }
            }
        }
    }
}
