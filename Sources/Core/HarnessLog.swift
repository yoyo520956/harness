import Foundation

final class HarnessLog: ObservableObject {
    static let shared = HarnessLog()
    @Published private(set) var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 300
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ s: String) {
        let line = "[\(Self.fmt.string(from: Date()))] \(s)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        let snapshot = lines
        lock.unlock()
        DispatchQueue.main.async { self.lines = snapshot }
    }
}
