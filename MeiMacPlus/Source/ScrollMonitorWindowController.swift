import AppKit
import SwiftUI

/// Live view of the scroll engine's decisions — incoming wheel deltas, the
/// chosen action, and the synthetic emissions. A tuning aid for smoothing
/// feel and blacklist coverage; opened from the menu or settings.
final class ScrollMonitorWindowController: NSWindowController, NSWindowDelegate {
    private var escapeToken: WindowEscapeCloser.Token?

    private let refreshTimer: Timer

    init(store: ScrollMonitorStore) {
        let viewModel = ScrollMonitorViewModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("scrollmonitor.title")
        window.contentView = NSHostingView(rootView: ScrollMonitorView(viewModel: viewModel))
        window.isReleasedWhenClosed = false
        // Creating/destroying the keep-awake virtual display reconfigures
        // screens; without these the system can relocate or hide the window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { _ in
            viewModel.refresh()
        }
        refreshTimer = timer
        super.init(window: window)
        window.delegate = self
        RunLoop.main.add(timer, forMode: .common)
        escapeToken = WindowEscapeCloser.attach(to: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer.invalidate()
        escapeToken?.invalidate()
    }
}

@MainActor
private final class ScrollMonitorViewModel: ObservableObject {
    @Published private(set) var records: [ScrollMonitorStore.Record] = []

    private let store: ScrollMonitorStore
    private var startedAt: TimeInterval = CACurrentMediaTime()

    init(store: ScrollMonitorStore) {
        self.store = store
    }

    func refresh() {
        records = store.snapshot()
    }

    func clear() {
        store.clear()
        startedAt = CACurrentMediaTime()
        records = []
    }

    /// Seconds since the monitor opened, for the relative timestamp column.
    func relativeTime(_ record: ScrollMonitorStore.Record) -> String {
        String(format: "%.2f", record.timestamp - startedAt)
    }
}

private struct ScrollMonitorView: View {
    @ObservedObject var viewModel: ScrollMonitorViewModel

    private func decisionLabel(_ decision: String) -> (String, Color) {
        switch decision {
        case "smooth": return (L("scrollmonitor.decision.smooth"), .accentColor)
        case "reverse": return (L("scrollmonitor.decision.reverse"), .orange)
        case "emit": return (L("scrollmonitor.decision.emit"), .green)
        default: return (L("scrollmonitor.decision.pass"), .secondary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("scrollmonitor.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("scrollmonitor.clear")) { viewModel.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Table(viewModel.records) {
                TableColumn(L("scrollmonitor.col.time")) { record in
                    Text(viewModel.relativeTime(record)).monospacedDigit()
                }
                TableColumn(L("scrollmonitor.col.source")) { record in
                    Text(record.source.rawValue)
                }
                TableColumn(L("scrollmonitor.col.delta")) { record in
                    Text("↓\(record.dy ?? 0) →\(record.dx ?? 0)").monospacedDigit()
                }
                TableColumn(L("scrollmonitor.col.decision")) { record in
                    let (label, color) = decisionLabel(record.decision)
                    Text(label).foregroundStyle(color)
                }
                TableColumn(L("scrollmonitor.col.app")) { record in
                    Text(record.app ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { viewModel.refresh() }
    }
}
