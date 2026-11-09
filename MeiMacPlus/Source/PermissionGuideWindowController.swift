import AppKit
import ApplicationServices
import SwiftUI

/// First-run window that walks the user through granting Accessibility
/// permission, polls for the grant, and reports back.
final class PermissionGuideWindowController: NSWindowController, NSWindowDelegate {

    var onPermissionGranted: (() -> Void)?

    private var pollTimer: Timer?
    private let model = PermissionGuideModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("permission.title")
        window.contentView = NSHostingView(rootView: PermissionGuideView(model: model))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if CmdQInterceptor.isProcessTrusted() {
                    self.stopPolling()
                    self.close()
                    self.onPermissionGranted?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }
}

@MainActor
final class PermissionGuideModel: ObservableObject {
    @Published var isTrusted = CmdQInterceptor.isProcessTrusted()

    func openSystemSettings() {
        // Deep links into System Settings keep breaking across macOS
        // versions (Tahoe moved the grant into "Device Control & Data
        // Access"). The system's own accessibility prompt navigates
        // correctly everywhere, so use it: it shows a dialog whose
        // "Open System Settings" button lands on the right pane.
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func recheck() {
        isTrusted = CmdQInterceptor.isProcessTrusted()
    }
}

struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel

    private var appIcon: NSImage {
        NSApplication.shared.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text(L("permission.heading"))
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                step(number: 1, text: L("permission.step1"))
                step(number: 2, text: L("permission.step2"))
                step(number: 3, text: L("permission.step3"))
            }
            .padding(.horizontal, 8)

            Text(L("permission.reason"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button(L("permission.openSettings")) { model.openSystemSettings() }
                    .keyboardShortcut(.defaultAction)
                Button(L("permission.recheck")) { model.recheck() }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 480)
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(nsColor: .controlAccentColor)))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
