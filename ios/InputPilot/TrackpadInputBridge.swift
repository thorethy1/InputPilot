import SwiftUI
import UIKit

struct TrackpadInputBridge: UIViewRepresentable {
    let move: (CGFloat, CGFloat) -> Void
    let scroll: (CGFloat) -> Void
    let click: (Int) -> Void
    let drag: (Bool) -> Void
    let rightClick: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = AppTheme.Radius.trackpad
        view.accessibilityLabel = "Remote trackpad"

        let movePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.moved(_:)))
        movePan.maximumNumberOfTouches = 1
        let scrollPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.scrolled(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        [movePan, scrollPan, tap, doubleTap, longPress].forEach {
            $0.delegate = context.coordinator
            view.addGestureRecognizer($0)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.owner = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: TrackpadInputBridge
        private var lastTapAt = Date.distantPast
        private var longPressIsDrag = false
        init(owner: TrackpadInputBridge) { self.owner = owner }

        @objc func moved(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .changed {
                let delta = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                owner.move(delta.x, delta.y)
            } else if recognizer.state == .cancelled || recognizer.state == .failed { owner.cancel() }
        }

        @objc func scrolled(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .changed {
                let delta = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                owner.scroll(delta.y)
            } else if recognizer.state == .cancelled || recognizer.state == .failed { owner.cancel() }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended {
                lastTapAt = Date()
                owner.click(1)
            }
        }
        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) { if recognizer.state == .ended { owner.click(2) } }
        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began {
                longPressIsDrag = Date().timeIntervalSince(lastTapAt) <= 1.0
                if longPressIsDrag { owner.drag(true) }
            }
            if recognizer.state == .ended {
                if longPressIsDrag { owner.drag(false) } else { owner.rightClick() }
                longPressIsDrag = false
            } else if recognizer.state == .cancelled || recognizer.state == .failed {
                if longPressIsDrag {
                    owner.drag(false)
                    owner.cancel()
                }
                longPressIsDrag = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer
        }
    }
}
