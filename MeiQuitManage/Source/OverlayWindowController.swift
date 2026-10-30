import AppKit
import SwiftUI

/// View-model state of the on-screen hold indicator.
final class OverlayModel: ObservableObject {
    @Published var fraction: Double = 0
    @Published var completed = false
    @Published var appName: String = ""
    @Published var appIcon: NSImage?
    @Published var remaining: TimeInterval = 0
}

/// The centered glass card shown while the user holds ⌘Q:
/// a progress ring around "Q", the target app, and the remaining time.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: model.completed ? 1 : max(0.003, model.fraction))
                    .stroke(
                        AngularGradient(
                            colors: [Color(nsColor: NSColor.systemBlue.withAlphaComponent(0.75)),
                                     Color(nsColor: NSColor.controlAccentColor)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1 / 60), value: model.fraction)

                if model.completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                } else {
                    Text(verbatim: "Q")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .overlay(alignment: .topTrailing) {
                            Text(verbatim: "⌘")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .offset(x: 14, y: 2)
                        }
                }
            }
            .frame(width: 128, height: 128)

            if !model.appName.isEmpty {
                HStack(spacing: 8) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                    }
                    Text(model.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 210)
            }

            if model.completed {
                Text(L("overlay.quitting"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(L("overlay.hint", model.remaining))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 30, bottom: 22, trailing: 30))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Owns the borderless, non-activating panel that presents `OverlayView`.
final class OverlayWindowController {

    private var panel: NSPanel?
    private let model = OverlayModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(app: NSRunningApplication?, delay: TimeInterval) {
        let view = OverlayView(model: model)
        let hosting = NSHostingView(rootView: view)

        let p: NSPanel
        if let existing = panel {
            p = existing
            p.contentView = hosting
        } else {
            p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.contentView = hosting
            panel = p
        }

        model.fraction = 0
        model.completed = false
        model.remaining = delay
        model.appName = app?.localizedName ?? L("overlay.unknownApp")
        model.appIcon = app?.icon

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = p.frame.size
            p.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        }

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            p.animator().alphaValue = 1
        }
    }

    func update(fraction: Double, remaining: TimeInterval) {
        guard panel?.isVisible == true, !model.completed else { return }
        model.fraction = fraction
        model.remaining = remaining
    }

    /// Flash the completion state, then fade out.
    func showCompletion(thenHideAfter delay: TimeInterval = 0.35) {
        guard panel?.isVisible == true else { return }
        model.completed = true
        model.fraction = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}
