import AppKit
import SwiftUI

/// The visual settings window: master switch, delay slider, overlay toggle,
/// launch-at-login, and the app whitelist editor.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("settings.title")
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
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

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItemManager.isEnabled
    @State private var manualBundleID = ""

    var body: some View {
        Form {
            Section {
                Toggle(L("settings.enable"), isOn: $settings.enabled)
                Toggle(L("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        if !LoginItemManager.setEnabled(on) {
                            launchAtLogin = LoginItemManager.isEnabled
                        }
                    }
            } header: {
                Text(L("settings.section.general"))
            }

            Section {
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
            } header: {
                Text(L("settings.section.hold"))
            } footer: {
                Text(L("settings.delay.footer"))
                    .font(.footnote)
            }

            Section {
                Toggle(L("settings.keepAwake"), isOn: $settings.keepAwakeOnLidClose)
            } header: {
                Text(L("settings.section.keepAwake"))
            } footer: {
                Text(L("settings.keepAwake.footer"))
                    .font(.footnote)
            }

            Section {
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
                    List {
                        ForEach(settings.whitelist, id: \.self) { bundleID in
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
                                Button {
                                    settings.whitelist.removeAll { $0 == bundleID }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 96, maxHeight: 180)
                }

                HStack {
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
                }

                HStack {
                    TextField(L("settings.whitelist.manualPlaceholder"), text: $manualBundleID)
                        .onSubmit(addManual)
                    Button(L("settings.whitelist.add"), action: addManual)
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(L("settings.section.whitelist"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
    }

    @State private var runningSelection: String?

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

/// Small helper that resolves bundle IDs to names/icons for the whitelist UI.
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
