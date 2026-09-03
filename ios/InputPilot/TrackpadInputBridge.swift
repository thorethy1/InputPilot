import SwiftUI
import UIKit

/// Arbitrates two-finger scrolling, pinch-to-zoom and two-/three-finger taps
/// from raw touch geometry. UIKit pan and pinch recognizers start on
/// different signals, so a pinch could be mistaken for a scroll and vice
/// versa. This recognizer instead watches both the centroid translation and
/// the finger distance itself and locks onto whichever intent crosses its
/// threshold first; the lock never changes until the fingers lift.
final class TwoFingerGestureRecognizer: UIGestureRecognizer {
    var onScroll: ((_ delta: CGFloat) -> Void)?
    var onScrollEnded: ((_ velocity: CGFloat) -> Void)?
    var onZoom: ((_ scaleChange: CGFloat) -> Void)?
    var onZoomEnded: ((_ cancelled: Bool) -> Void)?
    var onTwoFingerTap: (() -> Void)?
    var onThreeFingerTap: (() -> Void)?

    private struct TrackedTouch {
        let touch: UITouch
        let began: TimeInterval
        let startLocation: CGPoint
        var lastLocation: CGPoint
        var ended: TimeInterval = 0
    }

    private struct VelocitySample {
        let time: TimeInterval
        let y: Double
    }

    private enum TrackMode {
        case idle
        case scroll
        case zoom
    }

    private var tracked: [TrackedTouch] = []
    private var endedArchive: [TrackedTouch] = []
    private var touchedCount = 0
    private var mode: TrackMode = .idle
    private var arbiter: TwoFingerArbiter?
    private var scrollBaselineY: Double = 0
    private var zoomBaselineDistance: Double = 0
    private var velocitySamples: [VelocitySample] = []

    private static let tapMaxDuration: TimeInterval = 0.35
    private static let tapBeginSpread: TimeInterval = 0.15
    private static let tapSlop: CGFloat = 18
    private static let minimumPinchDistance: Double = 6
    private static let velocityWindow: TimeInterval = 0.08

    // MARK: - Geometry

    private func centroid(in view: UIView) -> CGPoint {
        let positions = tracked.prefix(2).map { $0.touch.location(in: view) }
        guard positions.count == 2 else { return .zero }
        return CGPoint(x: (positions[0].x + positions[1].x) / 2,
                       y: (positions[0].y + positions[1].y) / 2)
    }

    private func distance(in view: UIView) -> Double {
        guard tracked.count >= 2 else { return 0 }
        let a = tracked[0].touch.location(in: view)
        let b = tracked[1].touch.location(in: view)
        let dx = a.x - b.x, dy = a.y - b.y
        return Double((dx * dx + dy * dy).squareRoot())
    }

    // MARK: - Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view = self.view else {
            state = .failed
            return
        }
        if mode != .idle { return }  // Locked gestures ignore extra fingers.
        if tracked.isEmpty, endedArchive.isEmpty { touchedCount = 0 }
        for touch in touches {
            let location = touch.location(in: view)
            tracked.append(TrackedTouch(touch: touch, began: event.timestamp,
                                        startLocation: location, lastLocation: location))
            touchedCount += 1
        }
        // Four or more fingers never map to a gesture; give up cleanly.
        if touchedCount > 3 {
            reset()
            state = .failed
            return
        }
        // Scroll and zoom only track while exactly two concurrent fingers
        // were seen from the start of this touch sequence.
        if tracked.count == 2, touchedCount == 2, arbiter == nil {
            let center = centroid(in: view)
            arbiter = TwoFingerArbiter(centroidX: Double(center.x),
                                       centroidY: Double(center.y),
                                       distance: distance(in: view))
        } else if tracked.count > 2 {
            arbiter = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view = self.view else { return }
        for index in tracked.indices where touches.contains(tracked[index].touch) {
            tracked[index].lastLocation = tracked[index].touch.location(in: view)
        }
        switch mode {
        case .scroll:
            let y = Double(centroid(in: view).y)
            onScroll?(y - scrollBaselineY)
            scrollBaselineY = y
            appendVelocitySample(time: event.timestamp, y: y)
            state = .changed
        case .zoom:
            let d = distance(in: view)
            defer { zoomBaselineDistance = d }
            guard d >= Self.minimumPinchDistance,
                  zoomBaselineDistance >= Self.minimumPinchDistance else { return }
            let ratio = min(4, max(0.25, d / zoomBaselineDistance))
            onZoom?(CGFloat(ratio))
            state = .changed
        case .idle:
            let center = centroid(in: view)
            let d = distance(in: view)
            let locked = lockArbiter(centroidX: Double(center.x),
                                     centroidY: Double(center.y),
                                     distance: d)
            if locked == .zoom {
                mode = .zoom
                zoomBaselineDistance = d
                state = .began
            } else if locked == .scroll {
                mode = .scroll
                scrollBaselineY = Double(center.y)
                velocitySamples = [VelocitySample(time: event.timestamp, y: scrollBaselineY)]
                state = .began
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let view = self.view else { return }
        guard tracked.contains(where: { touches.contains($0.touch) }) else { return }
        var ended: [TrackedTouch] = []
        tracked = tracked.filter { record in
            guard touches.contains(record.touch) else { return true }
            var final = record
            final.lastLocation = record.touch.location(in: view)
            final.ended = event.timestamp
            ended.append(final)
            return false
        }
        if mode != .idle {
            finish(cancelled: false)
        } else {
            endedArchive.append(contentsOf: ended)
            guard tracked.isEmpty else { return }
            evaluateTap()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if mode != .idle {
            finish(cancelled: true)
        } else {
            reset()
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        tracked = []
        endedArchive = []
        touchedCount = 0
        mode = .idle
        arbiter = nil
        scrollBaselineY = 0
        zoomBaselineDistance = 0
        velocitySamples = []
    }

    // MARK: - Locking and outcomes

    private func lockArbiter(centroidX: Double, centroidY: Double, distance: Double) -> TwoFingerArbiter.Mode? {
        guard var current = arbiter else { return nil }
        let locked = current.update(centroidX: centroidX, centroidY: centroidY, distance: distance)
        arbiter = current
        return locked
    }

    private func finish(cancelled: Bool) {
        switch mode {
        case .scroll:
            onScrollEnded?(cancelled ? 0 : scrollVelocity())
        case .zoom:
            onZoomEnded?(cancelled)
        case .idle:
            break
        }
        reset()
        state = cancelled ? .cancelled : .ended
    }

    private func evaluateTap() {
        defer {
            reset()
            state = .failed
        }
        let records = endedArchive
        guard touchedCount == 2 || touchedCount == 3, records.count == touchedCount else { return }
        guard let firstBegan = records.map(\.began).min(),
              let lastBegan = records.map(\.began).max(),
              let lastEnded = records.map(\.ended).max() else { return }
        guard lastBegan - firstBegan <= Self.tapBeginSpread,
              lastEnded - firstBegan <= Self.tapMaxDuration else { return }
        for record in records {
            let dx = record.lastLocation.x - record.startLocation.x
            let dy = record.lastLocation.y - record.startLocation.y
            let displacement = (dx * dx + dy * dy).squareRoot()
            guard displacement <= Self.tapSlop else { return }
        }
        if touchedCount == 2 { onTwoFingerTap?() } else { onThreeFingerTap?() }
    }

    private func appendVelocitySample(time: TimeInterval, y: Double) {
        velocitySamples.append(VelocitySample(time: time, y: y))
        velocitySamples.removeAll { $0.time < time - 0.15 }
    }

    private func scrollVelocity() -> CGFloat {
        guard let last = velocitySamples.last else { return 0 }
        let anchor = velocitySamples.first { $0.time >= last.time - Self.velocityWindow }
            ?? velocitySamples.first
        guard let anchor, last.time - anchor.time >= 0.008 else { return 0 }
        return CGFloat((last.y - anchor.y) / (last.time - anchor.time))
    }
}

struct TrackpadInputBridge: UIViewRepresentable {
    let move: (CGFloat, CGFloat) -> Void
    let moveEnded: () -> Void
    let scroll: (CGFloat) -> Void
    let scrollEnded: (CGFloat) -> Void
    let click: (Int) -> Void
    let drag: (Bool) -> Void
    let rightClick: () -> Void
    let middleClick: () -> Void
    let zoom: (CGFloat) -> Void
    let zoomEnded: (_ cancelled: Bool) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = AppTheme.Radius.trackpad
        view.accessibilityLabel = "Remote trackpad"

        let movePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.moved(_:)))
        movePan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = 18
        let twoFinger = TwoFingerGestureRecognizer()
        context.coordinator.attach(twoFinger)
        [movePan, tap, doubleTap, longPress, twoFinger].forEach {
            $0.delegate = context.coordinator
            view.addGestureRecognizer($0)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.owner = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: TrackpadInputBridge
        private var dragEngaged = false
        private var dragBaseline = CGPoint.zero
        init(owner: TrackpadInputBridge) { self.owner = owner }

        func attach(_ recognizer: TwoFingerGestureRecognizer) {
            recognizer.onScroll = { [weak self] delta in self?.handleScroll(delta) }
            recognizer.onScrollEnded = { [weak self] velocity in self?.handleScrollEnded(velocity) }
            recognizer.onZoom = { [weak self] change in self?.handleZoom(change) }
            recognizer.onZoomEnded = { [weak self] cancelled in self?.handleZoomEnded(cancelled) }
            recognizer.onTwoFingerTap = { [weak self] in self?.handleTwoFingerTap() }
            recognizer.onThreeFingerTap = { [weak self] in self?.handleThreeFingerTap() }
        }

        @objc func moved(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .changed {
                let delta = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                owner.move(delta.x, delta.y)
            } else if recognizer.state == .ended || recognizer.state == .failed {
                // .failed fires when a second finger lands (the two-finger
                // recognizer takes over) or after taps; moveEnded only clears
                // a stale "Moving" state and is a no-op otherwise.
                owner.moveEnded()
            } else if recognizer.state == .cancelled {
                owner.cancel()
            }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { owner.click(1) }
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { owner.click(2) }
        }

        /// Long-press dual meaning: moving after the hold engages a drag,
        /// lifting without movement is a right click. Both paths guarantee a
        /// matching drag release.
        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                dragEngaged = false
                dragBaseline = recognizer.location(in: recognizer.view)
            case .changed:
                guard !dragEngaged else { return }
                let location = recognizer.location(in: recognizer.view)
                let dx = location.x - dragBaseline.x
                let dy = location.y - dragBaseline.y
                if TrackpadGestures.isDragEngagement(dx: dx, dy: dy) {
                    dragEngaged = true
                    owner.drag(true)
                }
            case .ended:
                if dragEngaged { owner.drag(false) } else { owner.rightClick() }
                dragEngaged = false
            case .cancelled, .failed:
                if dragEngaged {
                    owner.drag(false)
                    owner.cancel()
                }
                dragEngaged = false
            default:
                break
            }
        }

        private func handleScroll(_ delta: CGFloat) { owner.scroll(delta) }
        private func handleScrollEnded(_ velocity: CGFloat) { owner.scrollEnded(velocity) }
        private func handleZoom(_ change: CGFloat) { owner.zoom(change) }
        private func handleZoomEnded(_ cancelled: Bool) { owner.zoomEnded(cancelled) }

        private func handleTwoFingerTap() {
            // Never fire a right-click tap while a long-press drag is held.
            guard !dragEngaged else { return }
            owner.rightClick()
        }

        private func handleThreeFingerTap() {
            guard !dragEngaged else { return }
            owner.middleClick()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only the pointer pan may recognize alongside the long-press so
            // movement keeps flowing while a drag is held. Taps and double
            // taps must stay exclusive: as soon as the long press begins it
            // force-fails the pending tap, so a slow right-click can never be
            // followed by a stray tap click that closes its context menu.
            if gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer {
                return gestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer
            }
            return false
        }
    }
}
