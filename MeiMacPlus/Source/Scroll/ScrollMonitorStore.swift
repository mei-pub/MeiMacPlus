import Foundation
import os

private let monitorLog = Logger(subsystem: "com.meimacplus.MeiMacPlus", category: "scroll-monitor")

/// Ring buffer of recent scroll decisions, written on the tap thread and
/// read by the monitor window on the main thread.
final class ScrollMonitorStore {

    struct Record: Identifiable {
        enum Source: String {
            case mouse = "🖱"
            case trackpad = "🖐"
            case synthetic = "↪"
        }

        let id = UUID()
        /// Monotonic timestamp (`CACurrentMediaTime`).
        let timestamp: TimeInterval
        let source: Source
        /// Raw deltas as seen by the tap (already sign-flipped for reverse
        /// decisions; `nil` when the decision is unknown at record time).
        let dy: Int?
        let dx: Int?
        let decision: String
        let app: String?
    }

    private var records: [Record] = []
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = 240) {
        self.capacity = capacity
    }

    func append(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    /// Newest first, for display.
    func snapshot() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records.reversed()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }
}
