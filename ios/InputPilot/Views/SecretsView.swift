import SwiftData
import SwiftUI

enum SecretReferenceScanner {
    static func presetNames(referencing secretName: String, among presets: [(name: String, payload: String)]) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)\\bSECRET[ \\t]+" + NSRegularExpression.escapedPattern(for: secretName)
        ) else { return [] }
        var referenced: [String] = []
        for preset in presets {
            let range = NSRange(preset.payload.startIndex..., in: preset.payload)
            if regex.firstMatch(in: preset.payload, range: range) != nil { referenced.append(preset.name) }
        }
        return referenced
    }

    // Rewrites SECRET <oldName> lines to the new name so renames never break
    // preset references. Returns the number of updated payloads.
    static func updateReferences(from oldName: String, to newName: String, in presets: [HIDPreset]) -> Int {
        let pattern = "(?i)(\\bSECRET[ \\t]+)" + NSRegularExpression.escapedPattern(for: oldName)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        var updated = 0
        for preset in presets {
            let source = preset.payload
            let ns = source as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard regex.firstMatch(in: source, range: full) != nil else { continue }
            var pieces: [String] = []
            var cursor = 0
            regex.enumerateMatches(in: source, range: full) { match, _, _ in
                guard let match else { return }
                guard match.range.location >= cursor else { return }
                pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                // Keep the original SECRET keyword, brackets and whitespace;
                // only the name itself is replaced.
                let prefix = ns.substring(with: match.range(at: 1))
                pieces.append(prefix)
                pieces.append(newName)
                cursor = match.range.location + match.range.length
            }
            pieces.append(ns.substring(from: cursor))
            let rewritten = pieces.joined()
            if rewritten != source {
                preset.payload = rewritten
                updated += 1
            }
        }
        return updated
    }
}

struct SecretsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredSecret.name) private var secrets: [StoredSecret]
    @Query private var presets: [HIDPreset]
    @State private var showNewSecret = false
    @State private var renameTarget: StoredSecret?
    @State private var replaceTarget: StoredSecret?
    @State private var deleteTarget: StoredSecret?
    @State private var revealed: (id: UUID, value: String)?
    @State private var revealTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if secrets.isEmpty {
                ContentUnavailableView {
                    Label("No Secrets", systemImage: "key")
                } description: {
                    Text("Add a password or token to reuse it in presets.")
                } actions: {
                    Button("New Secret") { showNewSecret = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(secrets) { secret in
                        row(secret)
                    }
                }
            }
        }
        .navigationTitle("Secrets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewSecret = true
                } label: {
                    Label("New Secret", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewSecret) {
            NewSecretSheet(existingNames: secrets.map(\.name)) { name, value, note in
                createSecret(named: name, value: value, note: note)
            }
        }
        .sheet(item: $renameTarget) { secret in
            RenameSecretSheet(
                currentName: secret.name,
                otherNames: secrets.filter { $0.id != secret.id }.map(\.name),
                referencedPresets: SecretReferenceScanner.presetNames(
                    referencing: secret.name,
                    among: presets.map { (name: $0.name, payload: $0.payload) }
                )
            ) { newName in
                rename(secret: secret, to: newName)
            }
        }
        .sheet(item: $replaceTarget) { secret in
            ReplaceSecretValueSheet(secretName: secret.name) { newValue in
                replaceValue(of: secret, with: newValue)
            }
        }
        .confirmationDialog(
            "Delete ‘\(deleteTarget?.name ?? "")’?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete Secret", role: .destructive) { delete(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(deleteMessage(for: target))
        }
        .alert("Cannot Update Secret", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            hideRevealedValue()
        }
    }

    private func row(_ secret: StoredSecret) -> some View {
        HStack(spacing: AppTheme.Spacing.standard) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Text(secret.name)
                    .font(.body)
                if let revealed, revealed.id == secret.id {
                    Text(revealed.value)
                        .font(.body.monospaced())
                        .textSelection(.disabled)
                        .privacySensitive()
                        .transition(.opacity)
                } else {
                    Text(caption(secret))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                toggleReveal(secret)
            } label: {
                Image(systemName: revealed?.id == secret.id ? "eye.slash" : "eye")
                    .frame(minWidth: AppTheme.minimumInteractionSize, minHeight: AppTheme.minimumInteractionSize)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(revealed?.id == secret.id ? "Hide" : "Reveal") value of secret \(secret.name)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = secret
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                replaceTarget = secret
            } label: {
                Label("Replace Value", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(AppColors.info)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renameTarget = secret
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(AppColors.neutral)
        }
        .contextMenu {
            Button {
                renameTarget = secret
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                replaceTarget = secret
            } label: {
                Label("Replace Value…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                toggleReveal(secret)
            } label: {
                Label(revealed?.id == secret.id ? "Hide Value" : "Reveal Value", systemImage: revealed?.id == secret.id ? "eye.slash" : "eye")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = secret
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    private func caption(_ secret: StoredSecret) -> String {
        let updated = "Updated \(secret.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        return secret.note.isEmpty ? updated : "\(updated) · \(secret.note)"
    }

    private func deleteMessage(for secret: StoredSecret) -> String {
        let referenced = SecretReferenceScanner.presetNames(referencing: secret.name, among: presets.map { (name: $0.name, payload: $0.payload) })
        if referenced.isEmpty {
            return "The secret is removed from this device. Presets that reference it will fail until they are updated."
        }
        return "Used by: \(referenced.joined(separator: ", ")). These presets will fail until the secret is replaced."
    }

    private func toggleReveal(_ secret: StoredSecret) {
        if revealed?.id == secret.id {
            hideRevealedValue()
            return
        }
        do {
            let value = try SecretStore(context: context).value(forID: secret.id)
            revealTask?.cancel()
            withAnimation { revealed = (secret.id, value) }
            revealTask = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                hideRevealedValue()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hideRevealedValue() {
        revealTask?.cancel()
        revealTask = nil
        withAnimation { revealed = nil }
    }

    private func createSecret(named name: String, value: String, note: String) {
        do {
            try SecretStore(context: context).save(name: name, value: value, note: note)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(secret: StoredSecret, to newName: String) {
        do {
            let oldName = secret.name
            try SecretStore(context: context).rename(id: secret.id, to: newName)
            SecretReferenceScanner.updateReferences(from: oldName, to: newName, in: presets)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceValue(of secret: StoredSecret, with value: String) {
        do {
            try SecretStore(context: context).replaceValue(id: secret.id, with: value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ secret: StoredSecret) {
        do {
            try SecretStore(context: context).delete(id: secret.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        deleteTarget = nil
    }
}

private struct NewSecretSheet: View {
    let existingNames: [String]
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var note = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { existingNames.contains(trimmedName) }
    private var canSave: Bool { !trimmedName.isEmpty && !isDuplicate && !value.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("work-password"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                    if isDuplicate {
                        Label("A secret with this name already exists.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                } header: {
                    Text("Name")
                }
                Section("Value") {
                    SecureField("Password or token", text: $value)
                        .privacySensitive()
                }
                Section {
                    TextField("Optional note", text: $note)
                } header: {
                    Text("Note")
                } footer: {
                    Text("The value is stored in the iOS Keychain. Presets reference it by name with [SECRET name].")
                }
            }
            .navigationTitle("New Secret")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        onSave(trimmedName, value, note.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}

private struct RenameSecretSheet: View {
    let currentName: String
    let otherNames: [String]
    let referencedPresets: [String]
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !otherNames.contains(trimmedName) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if referencedPresets.isEmpty {
                        Text("No presets reference this secret by name.")
                    } else {
                        Text("[SECRET] lines in \(referencedPresets.joined(separator: ", ")) are updated automatically.")
                    }
                }
            }
            .navigationTitle("Rename Secret")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        dismissSheet()
                        onSave(trimmedName)
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear { name = currentName }
        }
    }

    private func dismissSheet() {
        name = ""
        dismiss()
    }
}

private struct ReplaceSecretValueSheet: View {
    let secretName: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New value", text: $value)
                        .privacySensitive()
                } header: {
                    Text("New Value for ‘\(secretName)’")
                } footer: {
                    Text("The old value is replaced immediately. The previous value is not shown.")
                }
            }
            .navigationTitle("Replace Value")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") {
                        dismiss()
                        onSave(value)
                    }
                    .disabled(value.isEmpty)
                }
            }
        }
    }
}
