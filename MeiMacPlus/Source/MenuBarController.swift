import AppKit

/// The menu bar (status item) facade: custom-drawn template icon that
/// reflects the enabled state, and a menu exposing all controls.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private weak var owner: AppDelegate?

    /// Menu rebuild requested right before presentation so state marks stay fresh.
    var onToggleEnabled: (() -> Void)?
    var onSetDelay: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onToggleKeepAwake: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    func install(owner: AppDelegate) {
        self.owner = owner
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusIcon(enabled: true, keepAwake: false)
        item.button?.toolTip = L("menubar.tooltip")
        statusItem = item

        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func refresh() {
        guard let settings = owner?.settings else { return }
        statusItem?.button?.image = Self.statusIcon(
            enabled: settings.enabled,
            keepAwake: settings.keepAwakeOnLidClose
        )
        statusItem?.button?.toolTip = settings.keepAwakeOnLidClose
            ? L("menubar.tooltip.awake")
            : L("menubar.tooltip")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - Menu construction

    private func rebuild() {
        guard let owner else { return }
        let settings = owner.settings
        menu.removeAllItems()

        let trusted = CmdQInterceptor.isProcessTrusted()

        let statusLine = NSMenuItem(
            title: trusted
                ? (settings.enabled ? L("menubar.status.active") : L("menubar.status.paused"))
                : L("menubar.status.noPermission"),
            action: nil, keyEquivalent: ""
        )
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let enableItem = NSMenuItem(
            title: L("menubar.enable"),
            action: #selector(toggleEnabled(_:)), keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.state = settings.enabled && trusted ? .on : .off
        enableItem.isEnabled = trusted
        menu.addItem(enableItem)

        let delayMenu = NSMenu(title: L("menubar.delay"))
        for ms in [500, 1000, 2000, 3000] {
            let item = NSMenuItem(
                title: L("menubar.delay.seconds", Double(ms) / 1000),
                action: #selector(setDelay(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = ms
            item.state = settings.delayMilliseconds == ms ? .on : .off
            delayMenu.addItem(item)
        }
        let custom = NSMenuItem(
            title: L("menubar.delay.custom"),
            action: #selector(openSettings(_:)), keyEquivalent: ""
        )
        custom.target = self
        delayMenu.addItem(.separator())
        delayMenu.addItem(custom)

        let delayItem = NSMenuItem(
            title: L("menubar.delay"), action: nil, keyEquivalent: ""
        )
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        let settingsItem = NSMenuItem(
            title: L("menubar.settings"),
            action: #selector(openSettings(_:)), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: L("menubar.launchAtLogin"),
            action: #selector(toggleLoginItem(_:)), keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let keepAwakeItem = NSMenuItem(
            title: L("menubar.keepAwake"),
            action: #selector(toggleKeepAwake(_:)), keyEquivalent: ""
        )
        keepAwakeItem.target = self
        keepAwakeItem.state = settings.keepAwakeOnLidClose ? .on : .off
        menu.addItem(keepAwakeItem)

        if !trusted {
            let permissionItem = NSMenuItem(
                title: L("menubar.grantPermission"),
                action: #selector(grantPermission(_:)), keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: L("menubar.about", appName()),
            action: #selector(openAbout(_:)), keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: L("menubar.quit", appName()),
            action: #selector(quit(_:)), keyEquivalent: "q"
        )
        // The app's own Quit must not be subject to the hold delay.
        quitItem.keyEquivalentModifierMask = []
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func appName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "MeiMacPlus"
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: Any?) {
        onToggleEnabled?()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        onSetDelay?(sender.tag)
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        onToggleLoginItem?()
    }

    @objc private func toggleKeepAwake(_ sender: Any?) {
        onToggleKeepAwake?()
    }

    @objc private func grantPermission(_ sender: Any?) {
        owner?.showPermissionGuide()
    }

    @objc private func openAbout(_ sender: Any?) {
        onOpenAbout?()
    }

    @objc private func quit(_ sender: Any?) {
        onQuit?()
    }

    // MARK: - Status icon

    /// Monochrome template icon: a thin ring (echoing the app icon) and a
    /// centered "M+". Reduced opacity when both features are off. While
    /// keep-awake is on, a non-template copy is filled orange (the same
    /// treatment Awayke uses) so the icon reads as "lit".
    static func statusIcon(enabled: Bool, keepAwake: Bool) -> NSImage {
        let dimension = CGFloat(17)
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.lockFocus()

        let ink = NSColor.black.withAlphaComponent((enabled || keepAwake) ? 1.0 : 0.32)

        let rect = NSRect(x: 1.25, y: 1.25, width: dimension - 2.5, height: dimension - 2.5)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.6
        path.lineCapStyle = .round

        ink.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
            .foregroundColor: ink,
        ]
        let glyph = NSAttributedString(string: "M+", attributes: attributes)
        let size = glyph.size()
        glyph.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))

        image.unlockFocus()
        image.isTemplate = true

        guard keepAwake else { return image }
        // "Lit" variant: fill the drawn pixels with orange, preserving alpha.
        let lit = image.copy() as! NSImage
        lit.isTemplate = false
        lit.lockFocus()
        NSColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 1.0).set()
        NSRect(origin: .zero, size: lit.size).fill(using: .sourceAtop)
        lit.unlockFocus()
        return lit
    }
}
