import AppKit
import WebKit

/// Bilingual scripting help (getting started, module overview, searchable API
/// reference) rendered from the bundled HTML + the vendored docs.json —
/// strictly matching the embedded runtime version.
final class ScriptHelpWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("scripthelp.title")
        window.isReleasedWhenClosed = false
        window.center()

        let webView = WKWebView()
        webView.configuration.preferences.isElementFullscreenEnabled = true
        window.contentView = webView

        // Read access covers Resources/ so the page can fetch docs.json.
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("ScriptHelp.index.html").path) {
            let index = resources.appendingPathComponent("ScriptHelp.index.html")
            webView.loadFileURL(index, allowingReadAccessTo: resources)
        }

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
