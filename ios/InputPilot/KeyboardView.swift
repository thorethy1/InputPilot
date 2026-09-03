import SwiftUI
import UIKit

// MARK: - Modifier latching model

enum ModifierLatchState: Equatable {
    case off
    case latched
    case locked
}

struct ModifierLatches: Equatable {
    private(set) var oneShot: UInt8 = 0
    private(set) var locked: UInt8 = 0

    var active: UInt8 { oneShot | locked }

    mutating func cycle(_ bit: UInt8) {
        if oneShot & bit != 0 {
            oneShot &= ~bit
            locked |= bit
        } else if locked & bit != 0 {
            locked &= ~bit
        } else {
            oneShot |= bit
        }
    }

    mutating func consumeOneShot(bits: UInt8) {
        oneShot &= ~bits
    }

    mutating func clear() {
        oneShot = 0
        locked = 0
    }

    func contains(_ bit: UInt8) -> Bool { active & bit != 0 }

    func state(of bit: UInt8) -> ModifierLatchState {
        if locked & bit != 0 { return .locked }
        if oneShot & bit != 0 { return .latched }
        return .off
    }
}

struct KeyModifier: Identifiable, Hashable {
    let bit: UInt8
    let name: String
    let symbol: String
    let comboSymbol: String
    let comboName: String

    var id: UInt8 { bit }

    static let ctrlBit: UInt8 = 0x01
    static let shiftBit: UInt8 = 0x02
    static let altBit: UInt8 = 0x04
    static let cmdBit: UInt8 = 0x08

    static let all: [KeyModifier] = [
        KeyModifier(bit: ctrlBit, name: "Ctrl", symbol: "control", comboSymbol: "⌃", comboName: "ctrl"),
        KeyModifier(bit: shiftBit, name: "Shift", symbol: "shift", comboSymbol: "⇧", comboName: "shift"),
        KeyModifier(bit: altBit, name: "Alt", symbol: "option", comboSymbol: "⌥", comboName: "alt"),
        KeyModifier(bit: cmdBit, name: "Win", symbol: "command", comboSymbol: "⌘", comboName: "cmd")
    ]
}

enum KeyComboPresentation {
    private static let symbols: [(name: String, symbol: String)] = [
        ("ctrl", "⌃"), ("shift", "⇧"), ("alt", "⌥"), ("cmd", "⌘")
    ]

    static func display(for combo: String) -> String {
        var modifierPart = ""
        var keyPart = ""
        for part in combo.split(separator: "+") {
            if let match = symbols.first(where: { $0.name == part.lowercased() }) {
                modifierPart += match.symbol
            } else {
                keyPart = part.uppercased()
            }
        }
        return modifierPart + keyPart
    }
}

// MARK: - Transmission pacing

enum KeyboardTransmissionPacing {
    static func chunkLength(for characterCount: Int) -> Int {
        switch characterCount {
        case ..<120: 3
        case 120..<400: 6
        default: 12
        }
    }

    static func tickInterval(for characterCount: Int) -> Duration {
        switch characterCount {
        case ..<120: .milliseconds(70)
        case 120..<400: .milliseconds(45)
        default: .milliseconds(30)
        }
    }
}

// MARK: - Models

struct QuickShortcut: Identifiable, Hashable {
    let id: String
    let title: String
    let combo: String
    let icon: String

    static let defaults: [QuickShortcut] = [
        QuickShortcut(id: "copy", title: "Copy", combo: "ctrl+c", icon: "doc.on.doc"),
        QuickShortcut(id: "paste", title: "Paste", combo: "ctrl+v", icon: "doc.on.clipboard"),
        QuickShortcut(id: "cut", title: "Cut", combo: "ctrl+x", icon: "scissors"),
        QuickShortcut(id: "undo", title: "Undo", combo: "ctrl+z", icon: "arrow.uturn.backward"),
        QuickShortcut(id: "redo", title: "Redo", combo: "ctrl+shift+z", icon: "arrow.uturn.forward"),
        QuickShortcut(id: "selectAll", title: "Select All", combo: "ctrl+a", icon: "checklist"),
        QuickShortcut(id: "find", title: "Find", combo: "ctrl+f", icon: "magnifyingglass"),
        QuickShortcut(id: "appSwitcher", title: "App Switcher", combo: "alt+tab", icon: "square.stack.3d.up"),
        QuickShortcut(id: "reopenTab", title: "Reopen Tab", combo: "ctrl+shift+t", icon: "arrow.clockwise"),
        QuickShortcut(id: "spotlight", title: "Search", combo: "cmd+space", icon: "magnifyingglass.circle")
    ]
}

struct SpecialKey: Identifiable, Hashable {
    static let width: CGFloat = 92
    let id: String
    let label: String
    var icon: String?

    static let utilities: [SpecialKey] = [
        SpecialKey(id: "esc", label: "esc"),
        SpecialKey(id: "tab", label: "tab"),
        SpecialKey(id: "enter", label: "enter"),
        SpecialKey(id: "backspace", label: "backspace", icon: "delete.left"),
        SpecialKey(id: "delete", label: "del"),
        SpecialKey(id: "home", label: "home"),
        SpecialKey(id: "end", label: "end"),
        SpecialKey(id: "pageup", label: "pg up"),
        SpecialKey(id: "pagedown", label: "pg dn")
    ]

    static let arrows: [SpecialKey] = [
        SpecialKey(id: "up", label: "up", icon: "arrow.up"),
        SpecialKey(id: "left", label: "left", icon: "arrow.left"),
        SpecialKey(id: "down", label: "down", icon: "arrow.down"),
        SpecialKey(id: "right", label: "right", icon: "arrow.right")
    ]
}

struct KeyboardStatus: Equatable, Identifiable {
    enum Tone { case info, success, warning }

    let id = UUID()
    let icon: String
    let message: String
    let tone: Tone
}

struct TransmissionChip: Identifiable {
    let id: UUID
    let text: String
    let jitterX: CGFloat
}

// MARK: - Haptics

@MainActor
enum KeyboardHaptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Failure shake

private struct ShakeEffect: GeometryEffect {
    var progress: CGFloat = 0
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(progress * .pi * 4) * 7 * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - Composer text view

final class ComposerTextView: UITextView {
    var onInsert: ((String, Bool) -> Void)?
    var onDeleteAtEmpty: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    private var isPasteOperation = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var hasText: Bool { true }

    override func insertText(_ text: String) {
        let paste = isPasteOperation
        super.insertText(text)
        onInsert?(text, paste)
        notifyChange()
    }

    override func deleteBackward() {
        if markedTextRange == nil && text.isEmpty {
            onDeleteAtEmpty?()
            return
        }
        super.deleteBackward()
        notifyChange()
    }

    override func paste(_ sender: Any?) {
        isPasteOperation = true
        super.paste(sender)
        isPasteOperation = false
    }

    func applyProgrammaticText(_ value: String, cursorShift: Int, moveCaretToEnd: Bool = false) {
        text = value
        undoManager?.removeAllActions()
        defer { onTextChange?(text) }
        guard markedTextRange == nil else { return }
        if moveCaretToEnd {
            selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
            return
        }
        guard cursorShift != 0, let selection = selectedTextRange else { return }
        let length = offset(from: selection.start, to: selection.end)
        let location = offset(from: beginningOfDocument, to: selection.start)
        let target = max(0, location + cursorShift)
        guard let anchor = position(from: beginningOfDocument, offset: target) else {
            selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
            return
        }
        guard let head = position(from: anchor, offset: length) ?? position(from: endOfDocument, offset: 0) else { return }
        if let range = textRange(from: anchor, to: head) {
            selectedTextRange = range
        }
    }

    private func notifyChange() {
        undoManager?.removeAllActions()
        onTextChange?(text)
    }
}

extension ComposerTextView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        notifyChange()
    }
}

final class ComposerFieldBox {
    weak var view: ComposerTextView?

    var currentText: String { view?.text ?? "" }

    func replace(text: String, cursorShift: Int, moveCaretToEnd: Bool = false) {
        view?.applyProgrammaticText(text, cursorShift: cursorShift, moveCaretToEnd: moveCaretToEnd)
    }

    func focus() { view?.becomeFirstResponder() }
    func resign() { view?.resignFirstResponder() }
}

struct KeyboardComposerBridge: UIViewRepresentable {
    let box: ComposerFieldBox
    let onInsert: (String, Bool) -> Void
    let onDeleteAtEmpty: () -> Void
    let onTextChange: (String) -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView(frame: .zero)
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .default
        view.returnKeyType = .default
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Text composer"
        view.accessibilityHint = "Typed characters are transmitted to the connected computer as you type."
        view.onInsert = onInsert
        view.onDeleteAtEmpty = onDeleteAtEmpty
        view.onTextChange = onTextChange
        box.view = view
        return view
    }

    func updateUIView(_ uiView: ComposerTextView, context: Context) {}
}

// MARK: - Keyboard view

struct LiveKeyboardView: View {
    @ObservedObject var manager: HIDConnectionManager
    @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    @State private var latches = ModifierLatches()
    @State private var composerText = ""
    @State private var isReviewing = false
    @State private var drainTask: Task<Void, Never>?
    @State private var isTransmitting = false
    @State private var transmittedCount = 0
    @State private var skippedCharacters = 0
    @State private var transmissionChips: [TransmissionChip] = []
    @State private var sentConfirmationVisible = false
    @State private var sentBadgeTask: Task<Void, Never>?
    @State private var shakeProgress: CGFloat = 0
    @State private var status: KeyboardStatus?
    @State private var executedShortcutID: String?
    @State private var fieldBox = ComposerFieldBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: KeyboardLayout { KeyboardLayout(rawValue: layoutName) ?? .german }
    private var layoutSupported: Bool { manager.supports("keyboard_layout") }
    private var keysSupported: Bool { manager.supports("keyboard_key") }
    private var activeModifierPrefix: String {
        KeyModifier.all.filter { latches.contains($0.bit) }.map(\.comboSymbol).joined()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.standard) {
                composerCard
                if let status {
                    statusLine(status)
                }
                if !layoutSupported {
                    Label("This firmware cannot map text, so typing is unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !keysSupported {
                    Label("Special keys and shortcuts need keyboard support from the firmware.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                modifierBar
                keySections
                shortcutSection
            }
            .padding(.horizontal)
            .padding(.top, AppTheme.Spacing.compact)
            .padding(.bottom, AppTheme.Spacing.section)
        }
        .scrollDismissesKeyboard(.immediately)
        .onDisappear {
            drainTask?.cancel()
            drainTask = nil
            sentBadgeTask?.cancel()
            sentBadgeTask = nil
            isTransmitting = false
        }
    }

    // MARK: Composer

    private var composerCard: some View {
        VStack(spacing: AppTheme.Spacing.compact) {
            HStack(spacing: AppTheme.Spacing.compact) {
                layoutMenu
                transmissionIndicator
                Spacer()
                releaseAllButton
                dismissKeyboardButton
            }
            fieldCard
            actionRow
        }
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Host layout", selection: $layoutName) {
                ForEach(KeyboardLayout.allCases) { layout in
                    Text(layout.rawValue).tag(layout.rawValue)
                }
            }
        } label: {
            Label(layout.compactName, systemImage: "globe")
                .font(.footnote.weight(.semibold))
                .frame(minHeight: AppTheme.minimumInteractionSize)
        }
        .buttonStyle(.bordered)
        .disabled(!layoutSupported)
        .accessibilityLabel("Host keyboard layout: \(layout.rawValue)")
    }

    private var transmissionIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: isTransmitting)
            Text("TX")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .opacity(isTransmitting ? 1 : 0)
        .accessibilityHidden(true)
    }

    private var releaseAllButton: some View {
        Button {
            releaseAllKeys()
        } label: {
            Label("Release All", systemImage: "arrow.uturn.backward.circle")
                .font(.footnote.weight(.semibold))
                .frame(minHeight: AppTheme.minimumInteractionSize)
        }
        .buttonStyle(.bordered)
        .tint(AppColors.warning)
        .accessibilityLabel("Release all keys")
        .accessibilityHint("Releases every latched modifier and any key the device still holds.")
    }

    private var dismissKeyboardButton: some View {
        Button {
            fieldBox.resign()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.body.weight(.medium))
                .frame(minWidth: AppTheme.minimumInteractionSize, minHeight: AppTheme.minimumInteractionSize)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Dismiss keyboard")
    }

    private var fieldCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            KeyboardComposerBridge(
                box: fieldBox,
                onInsert: handleInsert,
                onDeleteAtEmpty: handleRemoteBackspace,
                onTextChange: { composerText = $0 }
            )
            .padding(AppTheme.Spacing.standard)
            .disabled(!layoutSupported)
            if composerText.isEmpty {
                Text("Type, dictate or paste…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(AppTheme.Spacing.standard)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 92, alignment: .topLeading)
        .overlay(alignment: .top) { transmissionOverlay }
        .overlay {
            if sentConfirmationVisible {
                sentBadge
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .strokeBorder(isReviewing ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .modifier(ShakeEffect(progress: shakeProgress))
    }

    private var sentBadge: some View {
        Label(transmittedCount == 1 ? "Sent 1 character" : "Sent \(transmittedCount) characters", systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, AppTheme.Spacing.standard)
            .padding(.vertical, AppTheme.Spacing.compact)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(AppColors.success.opacity(0.5), lineWidth: 1))
            .foregroundStyle(AppColors.success)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
    }

    private var actionRow: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: AppTheme.minimumInteractionSize)
            }
            .buttonStyle(.bordered)
            .disabled(!layoutSupported)
            .accessibilityLabel("Paste from clipboard")
            if isReviewing && !isTransmitting {
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Reviewing before send")
            }
            Spacer()
            if !composerText.isEmpty {
                Button {
                    clearComposer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .frame(minWidth: AppTheme.minimumInteractionSize, minHeight: AppTheme.minimumInteractionSize)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Clear composer")
            }
            Button {
                startTransmission()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: AppTheme.minimumInteractionSize)
            }
            .buttonStyle(.borderedProminent)
            .disabled(composerText.isEmpty || isTransmitting || !layoutSupported)
        }
    }

    private var transmissionOverlay: some View {
        ZStack(alignment: .top) {
            ForEach(transmissionChips) { chip in
                TransmissionChipView(chip: chip, reduceMotion: reduceMotion) {
                    transmissionChips.removeAll { $0.id == chip.id }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Modifiers

    private var modifierBar: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            ForEach(KeyModifier.all) { modifier in
                ModifierChip(modifier: modifier, state: latches.state(of: modifier.bit)) {
                    toggleModifier(modifier.bit)
                }
            }
        }
    }

    // MARK: Keys

    private var keySections: some View {
        VStack(spacing: AppTheme.Spacing.standard) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: SpecialKey.width), spacing: AppTheme.Spacing.compact)], spacing: AppTheme.Spacing.compact) {
                ForEach(SpecialKey.utilities) { key in
                    specialKeyButton(key)
                }
            }
            arrowCluster
        }
        .disabled(!keysSupported)
    }

    private func specialKeyButton(_ key: SpecialKey) -> some View {
        Button {
            sendSpecialKey(key)
        } label: {
            HStack(spacing: 4) {
                if !activeModifierPrefix.isEmpty {
                    Text(activeModifierPrefix)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if let icon = key.icon {
                    Image(systemName: icon)
                        .font(.callout)
                        .accessibilityHidden(true)
                } else {
                    Text(key.label)
                }
            }
        }
        .buttonStyle(KeyChipButtonStyle())
        .accessibilityLabel(accessibilityLabel(for: key))
    }

    private var arrowCluster: some View {
        HStack {
            Spacer()
            VStack(spacing: AppTheme.Spacing.compact) {
                specialKeyButton(SpecialKey.arrows[0])
                HStack(spacing: AppTheme.Spacing.compact) {
                    ForEach(SpecialKey.arrows.dropFirst()) { key in
                        specialKeyButton(key)
                    }
                }
            }
            .frame(width: SpecialKey.width * 3 + AppTheme.Spacing.compact * 2)
        }
        .disabled(!keysSupported)
    }

    // MARK: Shortcuts

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            Text("Quick Shortcuts")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.compact)], spacing: AppTheme.Spacing.compact) {
                ForEach(QuickShortcut.defaults) { shortcut in
                    ShortcutCard(shortcut: shortcut, succeeded: executedShortcutID == shortcut.id) {
                        runShortcut(shortcut)
                    }
                }
            }
        }
        .disabled(!keysSupported)
    }

    // MARK: Status

    private func statusLine(_ value: KeyboardStatus) -> some View {
        Label(value.message, systemImage: value.icon)
            .font(.caption)
            .foregroundStyle(toneColor(value.tone))
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task(id: value.id) {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeOut(duration: 0.25)) {
                    if status?.id == value.id { status = nil }
                }
            }
    }

    // MARK: Actions

    private func handleInsert(_ text: String, isPaste: Bool) {
        guard layoutSupported, !text.isEmpty else { return }
        composerText = fieldBox.currentText
        if isPaste {
            if isTransmitting {
                setStatus(KeyboardStatus(icon: "plus.circle", message: "Appended to the send queue.", tone: .info))
            } else {
                isReviewing = true
                KeyboardHaptics.medium()
                setStatus(KeyboardStatus(icon: "eye", message: "Review the pasted text, then tap Send.", tone: .info))
            }
        } else if !isReviewing {
            startTransmission()
        }
    }

    private func handleRemoteBackspace() {
        guard keysSupported else { return }
        KeyboardHaptics.light()
        Task { @MainActor in await manager.send(.key("backspace")) }
    }

    private func pasteFromClipboard() {
        guard layoutSupported else { return }
        let text = UIPasteboard.general.string ?? ""
        guard !text.isEmpty else {
            KeyboardHaptics.warning()
            setStatus(KeyboardStatus(icon: "clipboard", message: "The clipboard is empty or unavailable.", tone: .warning))
            return
        }
        let combined = fieldBox.currentText + text
        fieldBox.replace(text: combined, cursorShift: 0, moveCaretToEnd: true)
        composerText = fieldBox.currentText
        if isTransmitting {
            setStatus(KeyboardStatus(icon: "plus.circle", message: "Appended to the send queue.", tone: .info))
        } else {
            isReviewing = true
            KeyboardHaptics.medium()
            setStatus(KeyboardStatus(icon: "eye", message: "Review the text, then tap Send.", tone: .info))
            fieldBox.focus()
        }
    }

    private func startTransmission() {
        guard drainTask == nil, !composerText.isEmpty, layoutSupported else { return }
        let capturedLatches = latches
        let selectedLayout = layout
        isReviewing = false
        isTransmitting = true
        transmittedCount = 0
        skippedCharacters = 0
        sentBadgeTask?.cancel()
        sentBadgeTask = nil
        sentConfirmationVisible = false
        drainTask = Task { @MainActor in
            defer {
                drainTask = nil
                isTransmitting = false
            }
            guard manager.beginOrderedSession(lowLatency: false) else {
                triggerFailureFeedback()
                setStatus(KeyboardStatus(icon: "exclamationmark.triangle.fill", message: manager.lastError ?? "No connection is ready to send text.", tone: .warning))
                return
            }
            defer { manager.endOrderedSession() }
            var pendingOneShot = capturedLatches.oneShot
            var deliveredAny = false
            while !Task.isCancelled {
                let current = fieldBox.currentText
                guard !current.isEmpty else { break }
                let chunkLength = min(KeyboardTransmissionPacing.chunkLength(for: current.count), current.count)
                let chunk = String(current.prefix(chunkLength))
                let strokes: [HIDStroke]
                do {
                    strokes = try selectedLayout.strokes(for: chunk)
                } catch {
                    fieldBox.replace(text: String(current.dropFirst()), cursorShift: -1)
                    composerText = fieldBox.currentText
                    skippedCharacters += 1
                    continue
                }
                var sentAll = true
                for stroke in strokes {
                    var modifiers = stroke.modifiers | capturedLatches.locked
                    if pendingOneShot != 0 { modifiers |= pendingOneShot }
                    guard await manager.send(.keyboardReport(modifiers: modifiers, usage: stroke.usage)) else {
                        sentAll = false
                        break
                    }
                    if pendingOneShot != 0 {
                        latches.consumeOneShot(bits: pendingOneShot)
                        pendingOneShot = 0
                    }
                }
                guard sentAll else {
                    triggerFailureFeedback()
                    setStatus(KeyboardStatus(
                        icon: "exclamationmark.triangle.fill",
                        message: manager.lastError ?? "Sending stopped before the text was delivered.",
                        tone: .warning
                    ))
                    return
                }
                deliveredAny = true
                let liveText = fieldBox.currentText
                let removeCount = liveText.hasPrefix(chunk) ? chunk.count : min(chunk.count, liveText.count)
                if removeCount > 0 {
                    fieldBox.replace(text: String(liveText.dropFirst(removeCount)), cursorShift: -removeCount)
                    composerText = fieldBox.currentText
                    transmittedCount += removeCount
                    enqueueTransmissionChip(chunk)
                }
                try? await Task.sleep(for: KeyboardTransmissionPacing.tickInterval(for: liveText.count))
            }
            if deliveredAny && !Task.isCancelled {
                finishTransmissionSuccessfully()
            }
        }
    }

    @MainActor
    private func finishTransmissionSuccessfully() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            sentConfirmationVisible = true
        }
        KeyboardHaptics.success()
        if skippedCharacters > 0 {
            setStatus(KeyboardStatus(
                icon: "exclamationmark.triangle",
                message: skippedCharacters == 1 ? "Skipped 1 character that the host layout cannot type." : "Skipped \(skippedCharacters) characters that the host layout cannot type.",
                tone: .warning
            ))
        }
        sentBadgeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                sentConfirmationVisible = false
            }
        }
    }

    private func clearComposer() {
        drainTask?.cancel()
        drainTask = nil
        isTransmitting = false
        isReviewing = false
        transmissionChips.removeAll()
        fieldBox.replace(text: "", cursorShift: 0)
        composerText = ""
        KeyboardHaptics.light()
    }

    private func releaseAllKeys() {
        latches.clear()
        KeyboardHaptics.warning()
        Task { @MainActor in
            await manager.releaseAll()
            setStatus(KeyboardStatus(icon: "arrow.uturn.backward.circle.fill", message: "All modifiers and held keys released.", tone: .info))
        }
    }

    private func toggleModifier(_ bit: UInt8) {
        latches.cycle(bit)
        if latches.state(of: bit) == .locked {
            KeyboardHaptics.medium()
        } else {
            KeyboardHaptics.light()
        }
    }

    private func sendSpecialKey(_ key: SpecialKey) {
        guard keysSupported else { return }
        KeyboardHaptics.light()
        let prefix = KeyModifier.all.filter { latches.contains($0.bit) }.map(\.comboName)
        let oneShotBits = latches.oneShot
        Task { @MainActor in
            let sent: Bool
            if prefix.isEmpty {
                sent = await manager.send(.key(key.id))
            } else {
                sent = await manager.send(.keyCombo((prefix + [key.id]).joined(separator: "+")))
            }
            if sent && oneShotBits != 0 {
                latches.consumeOneShot(bits: oneShotBits)
            }
        }
    }

    private func runShortcut(_ shortcut: QuickShortcut) {
        guard keysSupported else { return }
        KeyboardHaptics.light()
        Task { @MainActor in
            let sent = await manager.send(.keyCombo(shortcut.combo))
            guard sent else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                executedShortcutID = shortcut.id
            }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.25)) {
                if executedShortcutID == shortcut.id { executedShortcutID = nil }
            }
        }
    }

    private func triggerFailureFeedback() {
        KeyboardHaptics.error()
        guard !reduceMotion else { return }
        shakeProgress = 0
        withAnimation(.easeOut(duration: 0.45)) {
            shakeProgress = 1
        }
    }

    private func enqueueTransmissionChip(_ text: String) {
        let chipText = text.count > 6 ? String(text.prefix(6)) + "…" : text
        let chip = TransmissionChip(
            id: UUID(),
            text: chipText,
            jitterX: CGFloat.random(in: -34...34)
        )
        transmissionChips.append(chip)
        if transmissionChips.count > 5 {
            transmissionChips.removeFirst(transmissionChips.count - 5)
        }
    }

    private func setStatus(_ newStatus: KeyboardStatus) {
        withAnimation(.easeOut(duration: 0.2)) {
            status = newStatus
        }
    }

    // MARK: Helpers

    private func accessibilityLabel(for key: SpecialKey) -> String {
        let prefix = activeModifierPrefix.isEmpty ? "" : "with \(prefixNames) "
        switch key.id {
        case "backspace": return prefix + "Backspace"
        case "delete": return prefix + "Forward delete"
        case "esc": return prefix + "Escape"
        case "pageup": return prefix + "Page up"
        case "pagedown": return prefix + "Page down"
        default: return prefix + key.label.capitalized
        }
    }

    private var prefixNames: String {
        KeyModifier.all.filter { latches.contains($0.bit) }.map(\.name).joined(separator: " ")
    }

    private func toneColor(_ tone: KeyboardStatus.Tone) -> Color {
        switch tone {
        case .info: .secondary
        case .success: AppColors.success
        case .warning: AppColors.warning
        }
    }
}

// MARK: - Chip views

private struct TransmissionChipView: View {
    let chip: TransmissionChip
    let reduceMotion: Bool
    let onFinished: () -> Void

    @State private var flying = false

    var body: some View {
        Text(chip.text)
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .offset(x: chip.jitterX, y: flying ? -84 : 4)
            .opacity(flying ? 0 : 1)
            .scaleEffect(flying ? 0.85 : 1)
            .task {
                if reduceMotion {
                    try? await Task.sleep(for: .milliseconds(350))
                    onFinished()
                } else {
                    try? await Task.sleep(for: .milliseconds(40))
                    withAnimation(.easeIn(duration: 0.6)) {
                        flying = true
                    }
                    try? await Task.sleep(for: .milliseconds(660))
                    onFinished()
                }
            }
    }
}

private struct ModifierChip: View {
    let modifier: KeyModifier
    let state: ModifierLatchState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: modifier.symbol)
                Text(modifier.name)
                if state == .locked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                }
                if state == .latched {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumInteractionSize)
            .background(background, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(border, lineWidth: state == .off ? 1 : 1.5)
            )
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: state)
        .accessibilityLabel("\(modifier.name) modifier")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to latch for the next key, tap again to lock, tap a third time to release.")
    }

    private var background: Color {
        switch state {
        case .off: Color.primary.opacity(0.06)
        case .latched: Color.accentColor.opacity(0.14)
        case .locked: Color.accentColor
        }
    }

    private var foreground: Color {
        switch state {
        case .off: Color.secondary
        case .latched: Color.accentColor
        case .locked: Color.white
        }
    }

    private var border: Color {
        switch state {
        case .off: Color.primary.opacity(0.12)
        case .latched: Color.accentColor.opacity(0.6)
        case .locked: Color.clear
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .off: "Off"
        case .latched: "Latched, applies to the next key"
        case .locked: "Locked"
        }
    }
}

struct KeyChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(configuration.isPressed ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumInteractionSize)
            .background(
                (configuration.isPressed ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(configuration.isPressed ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ShortcutCard: View {
    let shortcut: QuickShortcut
    let succeeded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: shortcut.icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(KeyComboPresentation.display(for: shortcut.combo))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if succeeded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(AppTheme.Spacing.compact + 2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shortcut.title), \(KeyComboPresentation.display(for: shortcut.combo))")
    }
}

extension KeyboardLayout {
    var compactName: String {
        switch self {
        case .german: "DE"
        case .us: "US"
        }
    }
}
