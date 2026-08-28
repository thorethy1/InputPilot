import SwiftUI
import UIKit

enum KeyboardInputEvent {
    case insert(String)
    case deleteBackward
}

struct KeyboardInputBridge: UIViewRepresentable {
    var autoFocus = false
    let onEvent: (KeyboardInputEvent) -> Void

    func makeUIView(context: Context) -> RemoteKeyboardTextView {
        let view = RemoteKeyboardTextView()
        view.onEvent = onEvent
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.text = ""
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .default
        view.returnKeyType = .default
        view.accessibilityLabel = "Remote keyboard input"
        if autoFocus { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ uiView: RemoteKeyboardTextView, context: Context) {}
}

final class RemoteKeyboardTextView: UITextView {
    var onEvent: ((KeyboardInputEvent) -> Void)?

    override func insertText(_ text: String) {
        onEvent?(.insert(text))
        self.text = ""
    }

    override func deleteBackward() {
        onEvent?(.deleteBackward)
        text = ""
    }

    override var hasText: Bool { true }
}
