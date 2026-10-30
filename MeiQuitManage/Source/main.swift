import AppKit

// MeiQuitManage — a macOS utility that adds a hold-to-quit delay to ⌘Q,
// inspired by the behavior of SlowQuitApps (https://github.com/dteoh/SlowQuitApps).
// This implementation is an independent Swift codebase (MIT licensed).

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
