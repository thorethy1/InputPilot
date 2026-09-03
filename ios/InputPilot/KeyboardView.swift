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
    static let visualQuietInterval: TimeInterval = 0.6
    static let visualFlightCap = 48
    static let visualFlightInterval: Duration = .milliseconds(220)

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

    static func flightLength(text: String, sentPrefix: Int, isQuiet: Bool) -> Int? {
        guard sentPrefix > 0, !text.isEmpty else { return nil }
        let region = min(sentPrefix, text.count)
        let prefix = text.prefix(region)
        if let lastBoundary = prefix.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let length = prefix.distance(from: prefix.startIndex, to: lastBoundary) + 1
            return min(length, visualFlightCap)
        }
        if isQuiet { return region }
        return region >= visualFlightCap ? visualFlightCap : nil
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
        QuickShortcut(id: "spotlight", title: "Search", combo: "cmd+space", icon: "magnifyingglass.circle"),
        QuickShortcut(id: "lockScreen", title: "Lock Screen", combo: "cmd+l", icon: "lock")
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

// MARK: - Liquid Glass surfaces

private extension View {
    @ViewBuilder
    func keyChipSurface(highlighted: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                highlighted ? .regular.tint(Color.accentColor.opacity(0.45)).interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            )
        } else {
            self
                .background(
                    highlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .strokeBorder(highlighted ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func modifierChipSurface(state: ModifierLatchState) -> some View {
        if #available(iOS 26.0, *) {
            let tint: Color? = state == .locked
                ? Color.accentColor
                : (state == .latched ? Color.accentColor.opacity(0.55) : nil)
            self.glassEffect(
                tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            )
        } else {
            self
                .background(
                    state == .off ? Color.primary.opacity(0.06) : (state == .latched ? Color.accentColor.opacity(0.14) : Color.accentColor),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .strokeBorder(
                            state == .off ? Color.primary.opacity(0.12) : (state == .latched ? Color.accentColor.opacity(0.6) : Color.clear),
                            lineWidth: state == .off ? 1 : 1.5
                        )
                )
        }
    }
}

// MARK: - Composer text view

final class ComposerTextView: UITextView {
    var onInsert: ((String, Bool) -> Void)?
    var onRemoteBackspaceRequested: (() -> Void)?
    var allowsLocalEditing: () -> Bool = { true }
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
        if markedTextRange == nil && (text.isEmpty || !allowsLocalEditing()) {
            onRemoteBackspaceRequested?()
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
    let onRemoteBackspaceRequested: () -> Void
    let allowsLocalEditing: () -> Bool
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
        view.onRemoteBackspaceRequested = onRemoteBackspaceRequested
        view.allowsLocalEditing = allowsLocalEditing
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
    @State private var visualDebt = 0
    @State private var lastActivityAt = Date.distantPast
    @State private var visualTask: Task<Void, Never>?
    @State private var liveSendTask: Task<Void, Never>?
    @State private var liveQueue: [String] = []
    @State private var transmissionChips: [TransmissionChip] = []
    @State private var shakeProgress: CGFloat = 0
    @State private var status: KeyboardStatus?
    @State private var executedShortcutID: String?
    @State private var fieldBox = ComposerFieldBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: KeyboardLayout { KeyboardLayout(rawValue: layoutName) ?? .german }
    private var layoutSupported: Bool { manager.supports("keyboard_layout") }
    private var keysSupported: Bool { manager.supports("keyboard_key") }
    private var isSending: Bool { isTransmitting || liveSendTask != nil }
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
            liveSendTask?.cancel()
            liveSendTask = nil
            visualTask?.cancel()
            visualTask = nil
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
                .symbolEffect(.pulse, options: .repeating, isActive: isSending)
            Text("TX")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .opacity(isSending ? 1 : 0)
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
                onRemoteBackspaceRequested: handleRemoteBackspace,
                allowsLocalEditing: { isReviewing || isTransmitting },
                onTextChange: { text in
                    composerText = text
                    visualDebt = min(visualDebt, text.count)
                }
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
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .strokeBorder(isReviewing ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .modifier(ShakeEffect(progress: shakeProgress))
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
        lastActivityAt = .now
        if isPaste {
            if isTransmitting {
                setStatus(KeyboardStatus(icon: "plus.circle", message: "Appended to the send queue.", tone: .info))
            } else {
                isReviewing = true
                KeyboardHaptics.medium()
                setStatus(KeyboardStatus(icon: "eye", message: "Review the pasted text, then tap Send.", tone: .info))
            }
        } else if isReviewing || isTransmitting {
            return
        } else {
            enqueueLiveInsert(text)
        }
    }

    private func handleRemoteBackspace() {
        guard keysSupported else { return }
        KeyboardHaptics.light()
        lastActivityAt = .now
        let current = fieldBox.currentText
        if !current.isEmpty {
            fieldBox.replace(text: String(current.dropLast()), cursorShift: -1)
        }
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
        lastActivityAt = .now
        fieldBox.replace(text: fieldBox.currentText + text, cursorShift: 0, moveCaretToEnd: true)
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
        guard drainTask == nil, layoutSupported else { return }
        if liveSendTask != nil {
            flushVisualsNow()
            return
        }
        let current = fieldBox.currentText
        if current.count - min(visualDebt, current.count) == 0 {
            flushVisualsNow()
            return
        }
        let capturedLatches = latches
        let selectedLayout = layout
        isReviewing = false
        isTransmitting = true
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
                let text = fieldBox.currentText
                let unsent = text.dropFirst(min(visualDebt, text.count))
                guard !unsent.isEmpty else { break }
                let chunkLength = min(KeyboardTransmissionPacing.chunkLength(for: unsent.count), unsent.count)
                let chunk = unsent.prefix(chunkLength)
                var consumed = 0
                var failed = false
                for character in chunk {
                    guard let characterStrokes = selectedLayout.strokes(for: character) else {
                        setStatus(KeyboardStatus(icon: "exclamationmark.triangle", message: "The character ‘\(character)’ is not available in the selected host layout.", tone: .warning))
                        consumed += 1
                        continue
                    }
                    var characterSent = true
                    for stroke in characterStrokes {
                        var modifiers = stroke.modifiers | capturedLatches.locked
                        if pendingOneShot != 0 { modifiers |= pendingOneShot }
                        guard await manager.send(.keyboardReport(modifiers: modifiers, usage: stroke.usage)) else {
                            characterSent = false
                            failed = true
                            break
                        }
                        if pendingOneShot != 0 {
                            latches.consumeOneShot(bits: pendingOneShot)
                            pendingOneShot = 0
                        }
                        deliveredAny = true
                    }
                    guard characterSent else { break }
                    consumed += 1
                }
                if failed {
                    visualDebt += consumed
                    triggerFailureFeedback()
                    setStatus(KeyboardStatus(
                        icon: "exclamationmark.triangle.fill",
                        message: manager.lastError ?? "Sending stopped before the text was delivered. Tap Send to retry.",
                        tone: .warning
                    ))
                    return
                }
                visualDebt += consumed
                lastActivityAt = .now
                startVisualDrain()
                try? await Task.sleep(for: KeyboardTransmissionPacing.tickInterval(for: unsent.count))
            }
            if deliveredAny && !Task.isCancelled {
                KeyboardHaptics.success()
            }
        }
    }

    private func enqueueLiveInsert(_ text: String) {
        liveQueue.append(text)
        guard liveSendTask == nil else { return }
        let selectedLayout = layout
        liveSendTask = Task { @MainActor in
            defer { liveSendTask = nil }
            guard !liveQueue.isEmpty else { return }
            guard manager.beginOrderedSession(lowLatency: false) else {
                liveQueue.removeAll()
                triggerFailureFeedback()
                isReviewing = true
                setStatus(KeyboardStatus(icon: "exclamationmark.triangle.fill", message: manager.lastError ?? "No connection is ready to send text.", tone: .warning))
                return
            }
            defer { manager.endOrderedSession() }
            while !Task.isCancelled, !liveQueue.isEmpty {
                let insert = liveQueue.removeFirst()
                guard await sendLiveInsert(insert, layout: selectedLayout) else {
                    liveQueue.removeAll()
                    triggerFailureFeedback()
                    isReviewing = true
                    setStatus(KeyboardStatus(
                        icon: "exclamationmark.triangle.fill",
                        message: manager.lastError ?? "Sending stopped. Edit the text and tap Send to retry.",
                        tone: .warning
                    ))
                    return
                }
                visualDebt += insert.count
                lastActivityAt = .now
                startVisualDrain()
            }
        }
    }

    private func sendLiveInsert(_ text: String, layout selectedLayout: KeyboardLayout) async -> Bool {
        for character in text {
            guard let characterStrokes = selectedLayout.strokes(for: character) else {
                setStatus(KeyboardStatus(icon: "exclamationmark.triangle", message: "The character ‘\(character)’ is not available in the selected host layout.", tone: .warning))
                continue
            }
            for stroke in characterStrokes {
                var modifiers = stroke.modifiers | latches.locked
                let oneShot = latches.oneShot
                if oneShot != 0 { modifiers |= oneShot }
                guard await manager.send(.keyboardReport(modifiers: modifiers, usage: stroke.usage)) else { return false }
                if oneShot != 0 { latches.consumeOneShot(bits: oneShot) }
            }
        }
        return true
    }

    private func startVisualDrain() {
        guard visualTask == nil else { return }
        visualTask = Task { @MainActor in
            defer { visualTask = nil }
            while !Task.isCancelled {
                guard visualDebt > 0 else { break }
                let text = fieldBox.currentText
                guard !text.isEmpty else {
                    visualDebt = 0
                    break
                }
                visualDebt = min(visualDebt, text.count)
                let isQuiet = lastActivityAt.distance(to: .now) >= KeyboardTransmissionPacing.visualQuietInterval
                if let length = KeyboardTransmissionPacing.flightLength(text: text, sentPrefix: visualDebt, isQuiet: isQuiet) {
                    visualDebt -= length
                    let chunk = String(text.prefix(length))
                    fieldBox.replace(text: String(text.dropFirst(length)), cursorShift: -length)
                    enqueueTransmissionChip(chunk)
                    try? await Task.sleep(for: KeyboardTransmissionPacing.visualFlightInterval)
                } else {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }

    private func flushVisualsNow() {
        let text = fieldBox.currentText
        let count = min(visualDebt, text.count)
        guard count > 0 else { return }
        visualDebt -= count
        let chunk = String(text.prefix(count))
        fieldBox.replace(text: String(text.dropFirst(count)), cursorShift: -count)
        enqueueTransmissionChip(chunk)
        KeyboardHaptics.light()
    }

    private func clearComposer() {
        drainTask?.cancel()
        drainTask = nil
        liveSendTask?.cancel()
        liveSendTask = nil
        liveQueue.removeAll()
        visualTask?.cancel()
        visualTask = nil
        isTransmitting = false
        isReviewing = false
        visualDebt = 0
        transmissionChips.removeAll()
        fieldBox.replace(text: "", cursorShift: 0)
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
        let chipText = text.count > 14 ? String(text.prefix(14)) + "…" : text
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
            .modifierChipSurface(state: state)
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: state)
        .accessibilityLabel("\(modifier.name) modifier")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to latch for the next key, tap again to lock, tap a third time to release.")
    }

    private var foreground: Color {
        switch state {
        case .off: Color.secondary
        case .latched: Color.accentColor
        case .locked: Color.white
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
            .keyChipSurface(highlighted: configuration.isPressed)
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
            .keyChipSurface()
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
