import Foundation

actor MouseEventCoalescer {
    typealias Sender = @Sendable (Int16, Int16) async -> Void
    private var x = 0
    private var y = 0
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let sender: Sender

    init(interval: Duration = .milliseconds(20), sender: @escaping Sender) {
        self.interval = interval
        self.sender = sender
    }

    func add(x: Int, y: Int) {
        self.x += x
        self.y += y
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: interval)
            await flush()
        }
    }

    func flush() async {
        task?.cancel()
        task = nil
        let dx = Int16(clamping: x), dy = Int16(clamping: y)
        x = 0; y = 0
        if dx != 0 || dy != 0 { await sender(dx, dy) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        x = 0; y = 0
    }
}

actor ScrollEventCoalescer {
    typealias Sender = @Sendable (Int16) async -> Void
    private var delta = 0
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let sender: Sender

    init(interval: Duration = .milliseconds(25), sender: @escaping Sender) {
        self.interval = interval
        self.sender = sender
    }

    func add(_ value: Int) {
        delta += value
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: interval)
            await flush()
        }
    }

    func flush() async {
        task?.cancel()
        task = nil
        let value = Int16(clamping: delta)
        delta = 0
        if value != 0 { await sender(value) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        delta = 0
    }
}
