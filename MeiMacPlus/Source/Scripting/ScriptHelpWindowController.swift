import AppKit
import WebKit

/// Bilingual scripting help (getting started, module overview, searchable API
/// reference) rendered from the bundled HTML + the vendored docs.json —
/// strictly matching the embedded runtime version.
final class ScriptHelpWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {


    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1150, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("scripthelp.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 560)
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
        webView.navigationDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Module/Spoon links point at hammerspoon.org — hand them to the
    /// default browser instead of navigating the help page away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
