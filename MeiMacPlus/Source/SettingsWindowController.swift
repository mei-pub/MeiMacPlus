import AppKit
import SwiftUI

/// The visual settings window: horizontal tabs along the top (like classic
/// macOS preferences), one pane of settings per capability.
///
/// Panes are built on an explicit `ScrollView` + card stack instead of
/// `Form`: Form's internal scrolling is unreliable inside `TabView` on
/// recent macOS, and nesting app-list `List`s inside it breaks sizing.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("settings.title")
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)
        // Creating/destroying the keep-awake virtual display reconfigures
        // screens; without these the system can relocate or hide the window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case holdToQuit
    case keepAwake
    case scroll
    case script

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("settings.section.general")
        case .holdToQuit: return L("settings.section.hold")
        case .keepAwake: return L("settings.section.keepAwake")
        case .scroll: return L("settings.section.scroll")
        case .script: return L("settings.section.script")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .holdToQuit: return "keyboard"
        case .keepAwake: return "cup.and.saucer"
        case .scroll: return "scroll"
        case .script: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background {
            // Esc closes the settings window (hidden cancel-action button).
            Button("") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
        }
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPane()
        case .holdToQuit: HoldToQuitSettingsPane()
        case .keepAwake: KeepAwakeSettingsPane()
        case .scroll: ScrollSettingsPane()
        case .script: ScriptSettingsPane()
        }
    }
}

// MARK: - Card building blocks

/// Scrollable pane background: window-gray canvas the cards sit on.
private struct SettingsPane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One grouped card: optional section title, rows, optional footnote —
/// the System-Settings look, drawn by hand so scrolling is always ours.
private struct SettingsCard<Content: View, Footer: View>: View {
    private let title: String?
    private let content: Content
    private let footer: Footer

    init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.trailing, 8)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItemManager.isEnabled

    var body: some View {
        SettingsPane {
            SettingsCard(L("settings.general.quick")) {
                Toggle(L("settings.enable"), isOn: $settings.enabled)
                Toggle(L("settings.keepAwake"), isOn: $settings.keepAwakeOnLidClose)
                Toggle(L("settings.scroll.enable"), isOn: $settings.scrollEnabled)
                Toggle(L("settings.script.enable"), isOn: $settings.scriptEnabled)
            } footer: {
                Text(L("settings.general.quick.footer"))
            }
            SettingsCard {
                Toggle(L("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        if !LoginItemManager.setEnabled(on) {
                            launchAtLogin = LoginItemManager.isEnabled
                        }
                    }
            } footer: {
                Text(L("settings.launchAtLogin.footer"))
            }
        }
    }
}

// MARK: - Hold to quit

private struct HoldToQuitSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var manualBundleID = ""
    @State private var runningSelection: String?

    var body: some View {
        SettingsPane {
            SettingsCard {
                Toggle(L("settings.enable"), isOn: $settings.enabled)
            } footer: {
                Text(L("settings.enable.footer"))
            }
            SettingsCard(L("settings.section.hold")) {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(settings.delayMilliseconds) },
                            set: { settings.delayMilliseconds = Int($0) }
                        ),
                        in: Double(AppSettings.minDelayMs)...Double(AppSettings.maxDelayMs),
                        step: 100
                    )
                    Text(L("settings.delay.value", Double(settings.delayMilliseconds) / 1000))
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                }
                Toggle(L("settings.overlay"), isOn: $settings.displayOverlay)
            } footer: {
                Text(L("settings.delay.footer"))
            }

            SettingsCard(L("settings.section.whitelist")) {
                Toggle(L("settings.invertList"), isOn: $settings.invertList)
                Text(settings.invertList ? L("settings.whitelist.footer.inverted") : L("settings.whitelist.footer.normal"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if settings.whitelist.isEmpty {
                    Text(L("settings.whitelist.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08))
                        )
                } else {
                    VStack(spacing: 4) {
                        ForEach(settings.whitelist, id: \.self) { bundleID in
                            appRow(bundleID) {
                                settings.whitelist.removeAll { $0 == bundleID }
                            }
                        }
                    }
                }

                Picker(L("settings.whitelist.addRunning"), selection: $runningSelection) {
                    Text(L("settings.whitelist.pick")).tag(String?.none)
                    ForEach(runningApps) { entry in
                        Text(entry.label).tag(String?.some(entry.bundleID))
                    }
                }
                .onChange(of: runningSelection) { selected in
                    if let id = selected {
                        if !settings.whitelist.contains(id) {
                            settings.whitelist.append(id)
                            settings.whitelist.sort()
                        }
                        runningSelection = nil
                    }
                }

                HStack {
                    TextField(L("settings.whitelist.manualPlaceholder"), text: $manualBundleID)
                        .onSubmit(addManual)
                    Button(L("settings.whitelist.add"), action: addManual)
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var runningApps: [AppCatalog.Entry] {
        AppCatalog.runningAppEntries()
    }

    private func addManual() {
        let id = manualBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !settings.whitelist.contains(id) {
            settings.whitelist.append(id)
            settings.whitelist.sort()
        }
        manualBundleID = ""
    }
}

// MARK: - Keep awake

private struct KeepAwakeSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsPane {
            SettingsCard(L("settings.section.keepAwake")) {
                Toggle(L("settings.keepAwake"), isOn: $settings.keepAwakeOnLidClose)
            } footer: {
                Text(L("settings.keepAwake.footer"))
            }
        }
    }
}

// MARK: - Mouse scrolling

private struct ScrollSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var scrollBlacklistSelection: String?
    @State private var manualScrollBlacklistID = ""

    var body: some View {
        SettingsPane {
            SettingsCard {
                Toggle(L("settings.scroll.enable"), isOn: $settings.scrollEnabled)
            }

            if settings.scrollEnabled {
                SettingsCard(L("settings.scroll.section.behavior")) {
                    Toggle(L("settings.scroll.smooth"), isOn: $settings.scrollSmoothEnabled)

                    if settings.scrollSmoothEnabled {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { Double(settings.scrollDurationMS) },
                                    set: { settings.scrollDurationMS = Int($0) }
                                ),
                                in: Double(AppSettings.minScrollDurationMS)...Double(AppSettings.maxScrollDurationMS),
                                step: 50
                            )
                            Text(L("settings.scroll.duration.value", settings.scrollDurationMS))
                                .monospacedDigit()
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        HStack {
                            Slider(
                                value: $settings.scrollGain,
                                in: AppSettings.minScrollGain...AppSettings.maxScrollGain,
                                step: 0.1
                            )
                            Text(L("settings.scroll.gain.value", settings.scrollGain))
                                .monospacedDigit()
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }

                    Toggle(L("settings.scroll.reverseVertical"), isOn: $settings.scrollReverseVertical)
                    Toggle(L("settings.scroll.reverseHorizontal"), isOn: $settings.scrollReverseHorizontal)

                    HStack {
                        Button(L("settings.scroll.openMonitor")) {
                            (NSApp.delegate as? AppDelegate)?.showScrollMonitor()
                        }
                        Spacer()
                    }
                } footer: {
                    Text(L("settings.scroll.footer"))
                }

                SettingsCard(L("settings.scroll.section.blacklist")) {
                    if settings.scrollBlacklist.isEmpty {
                        Text(L("settings.scroll.blacklist.empty"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )
                    } else {
                        VStack(spacing: 4) {
                            ForEach(settings.scrollBlacklist, id: \.self) { bundleID in
                                appRow(bundleID) {
                                    settings.scrollBlacklist.removeAll { $0 == bundleID }
                                }
                            }
                        }
                    }

                    Picker(L("settings.scroll.blacklist.addRunning"), selection: $scrollBlacklistSelection) {
                        Text(L("settings.scroll.blacklist.pick")).tag(String?.none)
                        ForEach(runningApps) { entry in
                            Text(entry.label).tag(String?.some(entry.bundleID))
                        }
                    }
                    .onChange(of: scrollBlacklistSelection) { selected in
                        if let id = selected {
                            if !settings.scrollBlacklist.contains(id) {
                                settings.scrollBlacklist.append(id)
                                settings.scrollBlacklist.sort()
                            }
                            scrollBlacklistSelection = nil
                        }
                    }

                    HStack {
                        TextField(L("settings.scroll.blacklist.manualPlaceholder"), text: $manualScrollBlacklistID)
                            .onSubmit(addManualScrollBlacklist)
                        Button(L("settings.scroll.blacklist.add"), action: addManualScrollBlacklist)
                            .disabled(manualScrollBlacklistID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private var runningApps: [AppCatalog.Entry] {
        AppCatalog.runningAppEntries()
    }

    private func addManualScrollBlacklist() {
        let id = manualScrollBlacklistID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !settings.scrollBlacklist.contains(id) {
            settings.scrollBlacklist.append(id)
            settings.scrollBlacklist.sort()
        }
        manualScrollBlacklistID = ""
    }
}

// MARK: - Scripting

private struct ScriptSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsPane {
            SettingsCard {
                Toggle(L("settings.script.enable"), isOn: $settings.scriptEnabled)
            } footer: {
                Text(L("settings.script.footer"))
            }

            if settings.scriptEnabled {
                SettingsCard(L("settings.script.section.files")) {
                    ScriptDirectoryPicker()
                    HStack {
                        Button(L("settings.script.console")) {
                            (NSApp.delegate as? AppDelegate)?.showScriptConsole()
                        }
                        Button(L("settings.script.reload")) {
                            (NSApp.delegate as? AppDelegate)?.reloadScripts()
                        }
                        Button(L("settings.script.help")) {
                            (NSApp.delegate as? AppDelegate)?.showScriptHelp()
                        }
                        Spacer()
                    }
                } footer: {
                    Text(L("settings.script.files.footer"))
                }

                SettingsCard(L("settings.spoons.section")) {
                    SpoonsManagerCard()
                }
            }
        }
    }
}

/// Scripts-directory display + chooser. An empty custom path means the
/// default resolution (~/.hammerspoon when present, else our own folder).
private struct ScriptDirectoryPicker: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isChoosing = false

    private var activeDirectory: String {
        ScriptConfig.prepareConfigDir(customPath: settings.scriptCustomPath).path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activeDirectory)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("settings.script.choose")) { isChoosing = true }
                if !settings.scriptCustomPath.isEmpty {
                    Button(L("settings.script.useDefault")) {
                        settings.scriptCustomPath = ""
                    }
                }
                Spacer()
                Button(L("settings.script.reveal")) {
                    ScriptConfig.ensureDirectory()
                    NSWorkspace.shared.activateFileViewerSelecting([ScriptConfig.configDir])
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first {
                settings.scriptCustomPath = url.path
            }
        }
    }
}

// MARK: - Shared row builder

/// Icon + name + bundle id + remove button, used by both app lists.
private func appRow(_ bundleID: String, onRemove: @escaping () -> Void) -> some View {
    HStack {
        if let icon = AppCatalog.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        }
        VStack(alignment: .leading, spacing: 1) {
            Text(AppCatalog.displayName(forBundleID: bundleID) ?? bundleID)
                .font(.system(size: 13, weight: .medium))
            Text(verbatim: bundleID)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: onRemove) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
    .padding(.vertical, 2)
}

/// Small helper that resolves bundle IDs to names/icons for the app lists.
enum AppCatalog {
    struct Entry: Identifiable {
        let bundleID: String
        let label: String
        var id: String { bundleID }
    }

    private static var cache: [String: (String, NSImage?)] = [:]

    static func runningAppEntries() -> [Entry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return Entry(bundleID: id, label: "\(app.localizedName ?? id)")
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func displayName(forBundleID bundleID: String) -> String? {
        info(forBundleID: bundleID)?.0
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        info(forBundleID: bundleID)?.1
    }

    private static func info(forBundleID bundleID: String) -> (String, NSImage?)? {
        if let cached = cache[bundleID] { return cached }
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: url)
        else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleID
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = (name, icon)
        return (name, icon)
    }
}
