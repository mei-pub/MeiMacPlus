import Foundation

/// Ring buffer of script console lines, written by `LuaRuntime.logHandler`
/// and read by the console window on the main thread.
final class ScriptLogStore {

    struct Record: Identifiable, Equatable {
        enum Kind {
            case stdout
            case command
            case result
        }

        let id = UUID()
        /// Wall-clock time of the line.
        let time: Date
        let text: String
        let kind: Kind

        init(time: Date, text: String, kind: Kind = .stdout) {
            self.time = time
            self.text = text
            self.kind = kind
        }
    }

    private var records: [Record] = []
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    func append(_ text: String, kind: Record.Kind = .stdout) {
        append([text], kind: kind)
    }

    func append(_ lines: [String], kind: Record.Kind = .stdout) {
        guard !lines.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        records.append(contentsOf: lines.map { Record(time: now, text: $0, kind: kind) })
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    /// Chronological order, for display.
    func snapshot() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }
}
