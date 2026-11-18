import AppKit
import SwiftUI

/// Script console: streaming log output from the Lua runtime plus a REPL
/// input line — the Hammerspoon console role, in MeiMacPlus clothing.
final class ScriptConsoleWindowController: NSWindowController, NSWindowDelegate {
    private var escapeToken: WindowEscapeCloser.Token?

    private let refreshTimer: Timer

    init(store: ScriptLogStore) {
        let viewModel = ScriptConsoleViewModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("scriptconsole.title")
        window.contentView = NSHostingView(rootView: ScriptConsoleView(viewModel: viewModel))
        window.isReleasedWhenClosed = false
        // Creating/destroying the keep-awake virtual display reconfigures
        // screens; without these the system can relocate or hide the window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { _ in
            MainActor.assumeIsolated { viewModel.refresh() }
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
private final class ScriptConsoleViewModel: ObservableObject {
    @Published private(set) var records: [ScriptLogStore.Record] = []
    @Published private(set) var running = false
    /// hs.console appearance overrides (set by hs.console.* from Lua).
    @Published private(set) var appearance = ConsoleAppearance()

    private let store: ScriptLogStore

    init(store: ScriptLogStore) {
        self.store = store
        running = LuaRuntime.shared.isRunning
    }

    func refresh() {
        let snapshot = store.snapshot()
        if snapshot.count != records.count {
            records = snapshot
        }
        running = LuaRuntime.shared.isRunning
        appearance = ConsoleAppearance.readFromHostConsole()
    }

    func clear() {
        store.clear()
        records = []
    }

    /// REPL entry: echoes the command, evaluates it, echoes the result —
    /// mirroring what Hammerspoon's console shows.
    func submit(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.append("> \(trimmed)", kind: .command)
        let output = LuaRuntime.shared.run(trimmed) ?? ""
        if !output.isEmpty {
            store.append(output.components(separatedBy: "\n"), kind: .result)
        }
        records = store.snapshot()
    }
}

/// Reads the hs.console appearance values hs.* scripts stored on the host's
/// MJConsoleWindowController stub (KVC — the class lives in MeiHSRuntime.dylib).
struct ConsoleAppearance: Equatable {
    var stdoutColor: NSColor?
    var commandColor: NSColor?
    var resultColor: NSColor?
    var font: NSFont?

    static func readFromHostConsole() -> ConsoleAppearance {
        guard let cls = NSClassFromString("MJConsoleWindowController") as? NSObject.Type,
              let singleton = cls.perform(NSSelectorFromString("singleton"))?.takeUnretainedValue() as? NSObject
        else { return ConsoleAppearance() }
        return ConsoleAppearance(
            stdoutColor: singleton.value(forKey: "MJColorForStdout") as? NSColor,
            commandColor: singleton.value(forKey: "MJColorForCommand") as? NSColor,
            resultColor: singleton.value(forKey: "MJColorForResult") as? NSColor,
            font: singleton.value(forKey: "consoleFont") as? NSFont
        )
    }
}

private struct ScriptConsoleView: View {
    @ObservedObject var viewModel: ScriptConsoleViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if viewModel.running {
                    Label(L("scriptconsole.status.running"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Label(L("scriptconsole.status.stopped"), systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("scriptconsole.clear")) { viewModel.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.records) { record in
                            HStack(alignment: .top, spacing: 8) {
                                Text(record.time, style: .time)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 62, alignment: .trailing)
                                Text(record.text)
                                    .font(viewModel.appearance.font.map { Font($0) } ?? .system(size: 12, design: .monospaced))
                                    .foregroundStyle(color(for: record))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .id(record.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: viewModel.records.count) { _ in
                    if let last = viewModel.records.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(L("scriptconsole.placeholder"), text: $input)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(submit)
                Button(L("scriptconsole.run"), action: submit)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 340)
    }

    private func submit() {
        viewModel.submit(input)
        input = ""
    }

    private func color(for record: ScriptLogStore.Record) -> Color {
        switch record.kind {
        case .command: return viewModel.appearance.commandColor.map(Color.init) ?? Color.accentColor
        case .result: return viewModel.appearance.resultColor.map(Color.init) ?? Color.primary
        case .stdout: return viewModel.appearance.stdoutColor.map(Color.init) ?? Color.primary
        }
    }
}
