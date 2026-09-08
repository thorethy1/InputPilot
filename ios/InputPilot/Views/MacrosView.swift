import SwiftData
import SwiftUI

struct MacrosView: View {
    @ObservedObject var manager: HIDConnectionManager
    @ObservedObject var controller: MacroController
    @Environment(\.modelContext) private var context
    @Query(sort: \HIDMacro.createdAt, order: .reverse) private var saved: [HIDMacro]
    @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    @State private var speed = 1.0
    @State private var repeatCount = 1
    @State private var delay = 0
    @State private var showSave = false
    @State private var macroName = ""
    @State private var editTarget: HIDMacro?
    @State private var deleteTarget: HIDMacro?
    @State private var errorMessage: String?
    @State private var search = ""

    private var busy: Bool { controller.isPlaying || controller.isRecording }
    private var filtered: [HIDMacro] {
        search.isEmpty ? saved : saved.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.macroDescription.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if controller.state != .ready {
                Section {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                        Label(controller.state.rawValue, systemImage: statusIcon)
                            .font(.headline)
                            .foregroundStyle(controller.state == .failed ? AppColors.error : Color.primary)
                        Text(controller.currentName).font(.subheadline)
                        if controller.isPlaying || controller.state == .completed {
                            ProgressView(value: controller.progress)
                                .accessibilityLabel("Macro progress")
                            Text("Repeat \(max(1, controller.iteration)) of \(controller.repeats.map { String($0) } ?? "∞") · \(controller.completedEvents)/\(controller.eventCount) events")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = controller.errorMessage { Text(message).font(.callout) }
                        if controller.isPlaying {
                            Button(role: .destructive) { controller.cancel() } label: {
                                Label(controller.state == .cancelling ? "Stopping…" : "Cancel Playback", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.state == .cancelling)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                HStack(spacing: AppTheme.Spacing.compact) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search macros", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear macro search")
                    }
                }
            }
            Section {
                Button {
                    if controller.isRecording {
                        controller.stopRecording()
                        macroName = "Macro \(saved.count + 1)"
                        showSave = true
                    } else { controller.startRecording() }
                } label: {
                    Label(controller.isRecording ? "Stop & Save Recording" : "Record Macro", systemImage: controller.isRecording ? "stop.circle" : "record.circle")
                }
                .disabled(controller.isPlaying || (!controller.isRecording && !controller.recorded.isEmpty))
                if !controller.isRecording && !controller.recorded.isEmpty {
                    Button("Save Recording (\(controller.recorded.count) events)") { showSave = true }
                    Button("Discard Recording", role: .destructive) { controller.recorded = [] }
                }
                if controller.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label("\(Int(controller.recordingDuration)) s · \(controller.recorded.count) events", systemImage: "record.circle.fill")
                            .foregroundStyle(AppColors.error)
                    }
                    Button("Discard Recording", role: .destructive) {
                        controller.stopRecording(); controller.recorded = []
                    }
                }
            } footer: {
                Text("Start recording, then use Trackpad or Keyboard. Stop and save here. Add reusable secrets in the event editor.")
            }
            Section("Playback") {
                Picker("Speed", selection: $speed) {
                    ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }
                Picker("Repeat", selection: $repeatCount) {
                    ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "Until cancelled" : "\($0)×").tag($0) }
                }
                Picker("Start delay", selection: $delay) {
                    ForEach([0, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            .disabled(busy)
            Section("Library") {
                if filtered.isEmpty {
                    ContentUnavailableView(saved.isEmpty ? "No Macros Yet" : "No Matching Macros", systemImage: "recordingtape", description: Text(saved.isEmpty ? "Record your first sequence of mouse and keyboard actions." : "Try another search."))
                }
                ForEach(filtered) { macro in
                    macroRow(macro)
                        .swipeActions {
                            Button(role: .destructive) { deleteTarget = macro } label: { Label("Delete", systemImage: "trash") }
                            Button { editTarget = macro } label: { Label("Edit", systemImage: "pencil") }
                        }
                        .contextMenu {
                            Button { run(macro) } label: { Label("Run", systemImage: "play") }
                                .disabled(busy)
                            Button { editTarget = macro } label: { Label("Rename & Edit", systemImage: "pencil") }
                            Button { duplicate(macro) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            Button(role: .destructive) { deleteTarget = macro } label: { Label("Delete", systemImage: "trash") }
                        }
                        .disabled(busy)
                }
            }
        }
        .sheet(item: $editTarget) { MacroEditorView(macro: $0) }
        .confirmationDialog("Delete Macro?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let macro = deleteTarget {
                    context.delete(macro)
                    do { try context.save() } catch { context.rollback(); errorMessage = "The macro could not be deleted." }
                }
                deleteTarget = nil
            }
        } message: { Text("“\(deleteTarget?.name ?? "")” will be permanently deleted.") }
        .alert("Save Macro", isPresented: $showSave) {
            TextField("Name", text: $macroName)
            Button("Save") { saveRecording() }.disabled(controller.recorded.isEmpty)
            Button("Discard", role: .cancel) { controller.recorded = [] }
        } message: { Text("\(controller.recorded.count) recorded events") }
        .alert("Could Not Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
            if !controller.recorded.isEmpty { Button("Retry Save") { showSave = true } }
        } message: { Text(errorMessage ?? "") }
        .sensoryFeedback(.success, trigger: controller.state == .completed)
        .sensoryFeedback(.error, trigger: controller.state == .failed)
    }

    private func macroRow(_ macro: HIDMacro) -> some View {
        HStack(spacing: AppTheme.Spacing.standard) {
            Image(systemName: "recordingtape")
                .font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(macro.name).font(.headline)
                if !macro.macroDescription.isEmpty { Text(macro.macroDescription).font(.subheadline).foregroundStyle(.secondary) }
                Text("\(macro.events.count) events · ≈ \((macro.events.last?.offset ?? 0) / speed + Double(macro.events.count) * 0.008 + 0.2, specifier: "%.1f") s / repeat")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { run(macro) } label: {
                Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Run \(macro.name)")
            .disabled(busy || macro.events.isEmpty)
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch controller.state {
        case .ready: "play.circle"
        case .waiting: "clock"
        case .running: "waveform"
        case .cancelling, .cancelled: "stop.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func run(_ macro: HIDMacro) {
        controller.play(macro, speed: speed, repeats: repeatCount == 0 ? nil : repeatCount,
                        delay: Double(delay), manager: manager,
                        layout: KeyboardLayout(rawValue: layoutName) ?? .german,
                        secretResolver: { try SecretStore(context: context).value(forID: $0) })
    }

    private func saveRecording() {
        let name = macroName.trimmingCharacters(in: .whitespacesAndNewlines)
        let macro = HIDMacro(name: name.isEmpty ? "Macro" : name, events: controller.recorded)
        context.insert(macro)
        do { try context.save(); controller.recorded = [] }
        catch { context.delete(macro); errorMessage = "The recording could not be saved. Your events are still available; try again." }
    }

    private func duplicate(_ macro: HIDMacro) {
        let copy = HIDMacro(name: macro.name + " Copy", description: macro.macroDescription, events: macro.events)
        copy.encodedEvents = macro.encodedEvents
        context.insert(copy)
        do { try context.save() } catch { context.delete(copy); errorMessage = "The macro could not be duplicated." }
    }
}

private struct MacroEventDraft: Identifiable {
    let id = UUID()
    var pause: Double
    var item: RecordedEvent

    var pointerX: Int16 {
        get { if case let .mouseMove(x, _) = item.event { return x }; return 0 }
        set { item.event = .mouseMove(newValue, pointerY) }
    }
    var pointerY: Int16 {
        get { if case let .mouseMove(_, y) = item.event { return y }; return 0 }
        set { item.event = .mouseMove(pointerX, newValue) }
    }
    var scroll: Int16 {
        get { if case let .scroll(value) = item.event { return value }; return 0 }
        set { item.event = .scroll(newValue) }
    }
    var button: MouseButton {
        get {
            switch item.event {
            case let .mouseDown(button), let .mouseUp(button), let .click(button): return button
            default: return .left
            }
        }
        set {
            switch item.event {
            case .mouseDown: item.event = .mouseDown(newValue)
            case .mouseUp: item.event = .mouseUp(newValue)
            default: item.event = .click(newValue)
            }
        }
    }
}

private struct MacroEditorView: View {
    let macro: HIDMacro
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredSecret.name) private var secrets: [StoredSecret]
    @State private var name: String
    @State private var notes: String
    @State private var events: [MacroEventDraft]
    @State private var errorMessage: String?

    init(macro: HIDMacro) {
        self.macro = macro
        _name = State(initialValue: macro.name)
        _notes = State(initialValue: macro.macroDescription)
        var previous = 0.0
        _events = State(initialValue: macro.events.map { item in
            defer { previous = item.offset }
            return MacroEventDraft(pause: max(0, item.offset - previous), item: item)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Macro") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $notes, axis: .vertical)
                }
                Section {
                    ForEach($events) { $event in
                        DisclosureGroup {
                            TextField("Pause before (seconds)", value: $event.pause, format: .number)
                                .keyboardType(.decimalPad)
                            eventFields($event)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(event.item.title)
                                Text("Wait \(event.pause, specifier: "%.2f") s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { events.remove(atOffsets: $0) }
                    .onMove { events.move(fromOffsets: $0, toOffset: $1) }
                    Menu {
                        Button("Text", systemImage: "text.cursor") { append(.typeText("")) }
                        Button("Key Combination", systemImage: "keyboard") { append(.keyCombo("CTRL+A")) }
                        Button("Pause", systemImage: "clock") { append(.ping, pause: 1) }
                        Button("Release All Input", systemImage: "hand.raised") { append(.releaseAll) }
                        if !secrets.isEmpty {
                            Menu("Secret", systemImage: "key") {
                                ForEach(secrets) { secret in
                                    Button(secret.name) {
                                        events.append(MacroEventDraft(pause: 0, item: RecordedEvent(offset: 0, event: .ping, secretID: secret.id)))
                                    }
                                }
                            }
                        }
                    } label: { Label("Add Event", systemImage: "plus") }
                } header: { Text("Events") } footer: {
                    Text("Use Edit to reorder or delete events. Pauses move with their events. Raw keyboard reports retain their recorded values. Held keys and mouse buttons are released after each repeat or when playback stops.")
                }
                if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.error) } }
            }
            .navigationTitle("Edit Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || events.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func eventFields(_ draft: Binding<MacroEventDraft>) -> some View {
        if let id = draft.wrappedValue.item.secretID {
            if let secret = secrets.first(where: { $0.id == id }) {
                Label(secret.name, systemImage: "key")
            } else {
                Label("Missing secret — select a replacement", systemImage: "key.slash").foregroundStyle(AppColors.error)
            }
            Picker("Secret", selection: draft.item.secretID) {
                if !secrets.contains(where: { $0.id == id }) {
                    Text("Missing Secret").tag(Optional(id))
                }
                ForEach(secrets) { Text($0.name).tag(Optional($0.id)) }
            }
        } else {
            switch draft.wrappedValue.item.event {
            case .mouseMove:
                TextField("Horizontal movement", value: draft.pointerX, format: .number)
                TextField("Vertical movement", value: draft.pointerY, format: .number)
            case .scroll:
                TextField("Scroll amount", value: draft.scroll, format: .number)
            case .mouseDown, .mouseUp, .click:
                Picker("Mouse button", selection: draft.button) {
                    ForEach(MouseButton.allCases, id: \.rawValue) { button in
                        Text(String(describing: button).capitalized).tag(button)
                    }
                }
            case let .typeText(text):
                TextField("Text", text: Binding(get: { if case let .typeText(value) = draft.wrappedValue.item.event { return value }; return text }, set: { draft.wrappedValue.item.event = .typeText($0) }), axis: .vertical)
            case let .keyCombo(combo), let .key(combo):
                TextField("Key combination", text: Binding(get: { switch draft.wrappedValue.item.event { case let .keyCombo(value), let .key(value): return value; default: return combo } }, set: { draft.wrappedValue.item.event = .keyCombo($0) }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            default:
                Text(draft.wrappedValue.item.event.diagnosticName).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func append(_ event: HIDEvent, pause: Double = 0) {
        events.append(MacroEventDraft(pause: pause, item: RecordedEvent(offset: 0, event: event)))
    }

    private func save() {
        guard events.allSatisfy({ $0.pause.isFinite && (0...3600).contains($0.pause) }) else {
            errorMessage = "Each pause must be between 0 and 3600 seconds."; return
        }
        var offset = 0.0
        let timeline = events.map { draft in
            offset += draft.pause
            var item = draft.item; item.offset = offset; return item
        }
        for item in timeline where item.secretID == nil {
            if case let .keyCombo(combo) = item.event, PresetScript.parseKeyCombo(combo) == nil {
                errorMessage = "One key combination is invalid. Use a combination such as CTRL+A."; return
            }
        }
        do {
            let data = try JSONEncoder().encode(timeline)
            let originalName = macro.name, originalNotes = macro.macroDescription, originalData = macro.encodedEvents
            macro.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            macro.macroDescription = notes; macro.encodedEvents = data
            do { try context.save(); dismiss() }
            catch {
                macro.name = originalName; macro.macroDescription = originalNotes; macro.encodedEvents = originalData
                errorMessage = "The macro could not be saved. Try again."
            }
        } catch { errorMessage = "The events could not be saved." }
    }
}
