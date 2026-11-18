import SwiftUI

/// Settings card listing every bundled official Spoon with a per-spoon
/// switch. All Spoons ship inside the app bundle; enabling one loads it
/// into the Lua runtime (start() called when provided) after a reload.
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
                    HStack(spacing: 10) {
                        Text(spoon.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 190, alignment: .leading)
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
