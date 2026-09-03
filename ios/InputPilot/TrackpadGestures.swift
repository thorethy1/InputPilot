import CoreGraphics
import Foundation

/// Mutually exclusive trackpad gesture states. `idle → moving → scrolling →
/// clicking → dragging → zooming`; at most one is active at a time.
enum TrackpadGestureState: Equatable {
    case idle
    case moving
    case scrolling
    case clicking
    case dragging
    case zooming

    var overlayTitle: String {
        switch self {
        case .idle: "Trackpad"
        case .moving: "Moving"
        case .scrolling: "Scrolling"
        case .clicking: "Clicking"
        case .dragging: "Dragging"
        case .zooming: "Zooming"
        }
    }
}

/// HID keyboard modifier bits used by the firmware `report` command.
enum HIDModifiers {
    static let none: UInt8 = 0
    static let ctrl: UInt8 = 0x01
}

/// Accumulates fractional deltas and emits whole steps so slow finger
/// movement is not lost to integer truncation.
struct FractionalAccumulator: Equatable, Sendable {
    private(set) var residue: Double = 0

    mutating func add(_ value: Double) -> Int {
        let total = residue + value
        let integer = Int(total.rounded(.towardZero))
        residue = total - Double(integer)
        return integer
    }

    /// Emits the remaining fractional movement (rounded) and resets.
    mutating func flush() -> Int {
        let integer = Int(residue.rounded(.towardZero))
        residue = 0
        return integer
    }

    mutating func reset() { residue = 0 }
}

/// Two-axis accumulator for pointer movement.
struct PointerAccumulator: Equatable, Sendable {
    private(set) var x = FractionalAccumulator()
    private(set) var y = FractionalAccumulator()

    mutating func add(dx: Double, dy: Double) -> (x: Int, y: Int) {
        return (x: x.add(dx), y: y.add(dy))
    }

    /// Emits remaining fractional movement and resets.
    mutating func flush() -> (x: Int, y: Int) { return (x: x.flush(), y: y.flush()) }

    mutating func reset() {
        x.reset()
        y.reset()
    }
}

/// Pure mapping helpers between trackpad gestures and HID reports.
enum TrackpadGestures {
    /// HID scroll lines contributed by a two-finger pan delta in points.
    /// Natural scrolling keeps the current direction; traditional inverts it.
    static func scrollContribution(panDeltaY: CGFloat, natural: Bool) -> Double {
        let direction: Double = natural ? -1 : 1
        return direction * Double(panDeltaY) / pixelsPerScrollLine
    }

    /// HID scroll lines contributed by a pinch scale change; zooming in
    /// scrolls the wheel up.
    static func zoomContribution(scaleChange: CGFloat) -> Double {
        (Double(scaleChange) - 1) * zoomLinesPerFullScale
    }

    static let pixelsPerScrollLine: Double = 5
    static let zoomLinesPerFullScale: Double = 10
}

/// Generates decaying inertial scroll lines from the pan-end velocity.
struct MomentumGenerator: Equatable, Sendable {
    let natural: Bool
    private(set) var velocity: Double
    private var accumulator = FractionalAccumulator()
    private var finished = false

    /// `velocity` is the pan velocity in points per second along the scroll
    /// axis at the moment the finger lifted.
    init(velocity: CGFloat, natural: Bool) {
        self.velocity = Double(velocity)
        self.natural = natural
        finished = abs(self.velocity) < Self.startThreshold
    }

    static let startThreshold: Double = 60
    static let stopThreshold: Double = 40
    static let tickInterval: Double = 1.0 / 60.0
    static let decayPerTick: Double = 0.94

    var isFinished: Bool { finished }

    /// Advances one tick and returns the scroll lines to send for it.
    mutating func nextLine() -> Int {
        guard !finished else { return 0 }
        velocity *= Self.decayPerTick
        let pixels = velocity * Self.tickInterval
        let direction: Double = natural ? -1 : 1
        let lines = accumulator.add(direction * pixels / TrackpadGestures.pixelsPerScrollLine)
        if abs(velocity) < Self.stopThreshold {
            finished = true
            return lines != 0 ? lines : accumulator.flush()
        }
        return lines
    }
}
