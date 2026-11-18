import SwiftUI

/// Usage text for one spoon, read from the assembler's spoon_usage.json.
struct SpoonUsage: Codable, Equatable {
    var how: String?
    var trigger: String?
    var text: String?
    var zh: String?
    var en: String?
}

enum SpoonUsageStore {
    private static var cache: [String: SpoonUsage]?
    private static let lock = NSLock()

    static func usage(for name: String) -> SpoonUsage? {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache[name] }
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("spoon_usage.json"),
            let data = try? Data(contentsOf: url),
            let dict = try? JSONDecoder().decode([String: SpoonUsage].self, from: data)
        else { cache = [:]; return nil }
        cache = dict
        return cache?[name]
    }
}

/// The bundled-Spoons manager: a native macOS Table (name | usage | switch)
/// that fills the remaining pane height and scrolls on its own — no nested
/// scroll containers, every spoon visible.
struct SpoonsManagerCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var filter = ""
    @State private var selection: SpoonSummary.ID?
    @State private var modCmd = false
    @State private var modAlt = false
    @State private var modCtrl = false
    @State private var modShift = false
    @State private var keyDraft = ""
    @State private var minutesDraft = 5

    private var visible: [SpoonSummary] {
        SpoonCatalog.all.filter {
            filter.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(filter) ||
                $0.zh.contains(filter) || $0.en.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(L("settings.spoons.filter"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text(L("settings.spoons.count", settings.spoonsEnabled.count, SpoonCatalog.all.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Table(visible, selection: $selection) {
                TableColumn(L("settings.spoons.col.name")) { spoon in
                    HStack(spacing: 4) {
                        Image(systemName: usageBadgeIcon(for: spoon.name))
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                        Text(spoon.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                }
                .width(180)

                TableColumn(L("settings.spoons.col.usage")) { spoon in
                    usageText(for: spoon)
                }

                TableColumn(L("settings.spoons.col.toggle")) { spoon in
                    Toggle("", isOn: binding(for: spoon.name))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .width(64)
            }
            .frame(minHeight: 320)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.03))
            )
            if let selected = visible.first(where: { $0.id == selection }) {
                triggerConfigBar(selected)
            }
            Text(L("settings.spoons.footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Per-spoon trigger editor: auto / hotkey / interval, applied live.
    @ViewBuilder
    private func triggerConfigBar(_ spoon: SpoonSummary) -> some View {
        let trigger = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
        HStack(spacing: 10) {
            Text(spoon.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Picker(L("settings.spoons.trigger.type"), selection: typeBinding(for: spoon)) {
                Text(L("settings.spoons.trigger.auto")).tag("auto")
                Text(L("settings.spoons.trigger.hotkey")).tag("hotkey")
                Text(L("settings.spoons.trigger.interval")).tag("interval")
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            if trigger.type == "hotkey" {
                HStack(spacing: 6) {
                    Toggle("⌘", isOn: modBinding(for: spoon, mod: "cmd", draft: $modCmd)).toggleStyle(.checkbox)
                    Toggle("⌥", isOn: modBinding(for: spoon, mod: "alt", draft: $modAlt)).toggleStyle(.checkbox)
                    Toggle("⌃", isOn: modBinding(for: spoon, mod: "ctrl", draft: $modCtrl)).toggleStyle(.checkbox)
                    Toggle("⇧", isOn: modBinding(for: spoon, mod: "shift", draft: $modShift)).toggleStyle(.checkbox)
                    TextField("key", text: keyBinding(for: spoon))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            } else if trigger.type == "interval" {
                HStack(spacing: 6) {
                    TextField("", value: minutesBinding(for: spoon), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text(L("settings.spoons.trigger.minutes"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L("settings.spoons.trigger.autoHint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onAppear { syncDrafts(spoon) }
        .onChange(of: selection) { _ in
            if let spoon = visible.first(where: { $0.id == selection }) {
                syncDrafts(spoon)
            }
        }
    }

    private func syncDrafts(_ spoon: SpoonSummary) {
        let t = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
        modCmd = t.mods.contains("cmd")
        modAlt = t.mods.contains("alt")
        modCtrl = t.mods.contains("ctrl")
        modShift = t.mods.contains("shift")
        keyDraft = t.key
        minutesDraft = t.minutes
    }

    private func typeBinding(for spoon: SpoonSummary) -> Binding<String> {
        Binding(
            get: { settings.spoonsTriggers[spoon.name]?.type ?? "auto" },
            set: { newType in
                var t = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
                t.type = newType
                if newType == "hotkey", t.mods.isEmpty {
                    t.mods = ["cmd", "alt"]; t.key = keyDraft.isEmpty ? "y" : keyDraft
                }
                settings.spoonsTriggers[spoon.name] = t
            })
    }

    private func modBinding(for spoon: SpoonSummary, mod: String, draft: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue },
            set: { on in
                draft.wrappedValue = on
                var t = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
                t.type = "hotkey"
                var set = Set(t.mods)
                if on { set.insert(mod) } else { set.remove(mod) }
                t.mods = ["cmd", "alt", "ctrl", "shift"].filter { set.contains($0) }
                settings.spoonsTriggers[spoon.name] = t
            })
    }

    private func keyBinding(for spoon: SpoonSummary) -> Binding<String> {
        Binding(
            get: { keyDraft },
            set: { newKey in
                keyDraft = newKey
                var t = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
                t.type = "hotkey"
                t.key = newKey
                settings.spoonsTriggers[spoon.name] = t
            })
    }

    private func minutesBinding(for spoon: SpoonSummary) -> Binding<Int> {
        Binding(
            get: { minutesDraft },
            set: { m in
                minutesDraft = max(1, m)
                var t = settings.spoonsTriggers[spoon.name] ?? SpoonTrigger()
                t.type = "interval"
                t.minutes = minutesDraft
                settings.spoonsTriggers[spoon.name] = t
            })
    }

    /// ⚡ auto / 🎚 needs-config badge
    private func usageBadgeIcon(for name: String) -> String {
        usage(for: name)?.how == "config" ? "slider.horizontal.3" : "bolt.fill"
    }

    private func usage(for name: String) -> SpoonUsage? {
        SpoonUsageStore.usage(for: name)
    }

    /// Column cell: hand-written user-view usage; trigger on its own line.
    @ViewBuilder
    private func usageText(for spoon: SpoonSummary) -> some View {
        let usage = usage(for: spoon.name)
        VStack(alignment: .leading, spacing: 2) {
            let text = usage?.text?.isEmpty == false ? usage!.text! : spoon.zh
            if let trigger = usage?.trigger, !trigger.isEmpty {
                Text(trigger)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { settings.spoonsEnabled.contains(name) },
            set: { on in
                if on {
                    settings.spoonsEnabled.insert(name)
                } else {
                    settings.spoonsEnabled.remove(name)
                }
            }
        )
    }
}
