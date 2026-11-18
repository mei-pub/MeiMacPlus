import SwiftUI

/// Settings card listing every bundled official Spoon with a per-spoon
/// switch. All Spoons ship inside the app bundle; enabling one loads it
/// into the Lua runtime (start() called when provided) after a reload.
/// Usage text for one spoon, read from the assembler's spoon_usage.json.
struct SpoonUsage: Codable, Equatable {
    var zh: String
    var en: String
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

struct SpoonsManagerCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var filter = ""
    @State private var expanded: Set<String> = []

    private var visible: [SpoonSummary] {
        SpoonCatalog.all.filter {
            filter.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(filter) ||
                $0.zh.contains(filter) || $0.en.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("settings.spoons.title"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("settings.spoons.intro"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L("settings.spoons.filter"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text(L("settings.spoons.count", settings.spoonsEnabled.count, SpoonCatalog.all.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(visible) { spoon in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Button {
                                if expanded.contains(spoon.name) {
                                    expanded.remove(spoon.name)
                                } else {
                                    expanded.insert(spoon.name)
                                }
                            } label: {
                                Image(systemName: expanded.contains(spoon.name)
                                      ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 14)
                            Text(spoon.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 170, alignment: .leading)
                            Text(spoon.zh)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: binding(for: spoon.name))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(spoon.name) {
                                expanded.remove(spoon.name)
                            } else {
                                expanded.insert(spoon.name)
                            }
                        }
                        if expanded.contains(spoon.name) {
                            spoonUsageView(spoon)
                                .padding(.horizontal, 34)
                                .padding(.bottom, 8)
                        }
                    }
                    if spoon.id != visible.last?.id {
                        Divider().padding(.leading, 10)
                    }
                }
            }
            .frame(height: 300)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(L("settings.spoons.footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func spoonUsageView(_ spoon: SpoonSummary) -> some View {
        let usage = SpoonUsageStore.usage(for: spoon.name)
        VStack(alignment: .leading, spacing: 4) {
            Text(L("settings.spoons.usage"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let zh = usage?.zh, !zh.isEmpty {
                Text(zh)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(spoon.zh)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let en = usage?.en, !en.isEmpty, en != usage?.zh {
                Text(en)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("hs.loadSpoon(\"\(spoon.name)\")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
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
