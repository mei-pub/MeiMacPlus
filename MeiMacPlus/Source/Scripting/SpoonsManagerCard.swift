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
            Table(visible) {
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
            Text(L("settings.spoons.footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
