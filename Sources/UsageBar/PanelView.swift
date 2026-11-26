import SwiftUI
import UsageCore

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @Binding var shortcut: ShortcutChoice
    let shortcutError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("UsageBar").font(.headline)
                    Text("Your subscription limits").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh all subscriptions")
                    .accessibilityLabel("Refresh all subscriptions")
                    .disabled(store.isLoading)
                Button { store.showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Keyboard shortcut settings")
                    .accessibilityLabel("Keyboard shortcut settings")
            }
            ForEach(store.providers) { provider in
                card(provider, state: store.states[provider.id] ?? UsageState())
            }
            if store.showingSettings {
                Divider()
                Picker("Global shortcut", selection: $shortcut) {
                    ForEach(ShortcutChoice.allCases) { choice in Text(choice.rawValue).tag(choice) }
                }
                if let shortcutError { Text(shortcutError).font(.caption).foregroundStyle(.red) }
            } else if let shortcutError {
                Text(shortcutError).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Label("Updates only when opened or refreshed", systemImage: "hand.tap")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func card(_ provider: Provider, state: UsageState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Text(provider.name).font(.headline)
                    if let image = Bundle.module.image(forResource: NSImage.Name(provider.name)) {
                        Image(nsImage: image)
                            .renderingMode(provider.kind == .codex ? .template : .original)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 18, height: 18)
                            .clipped()
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15))
                            .foregroundStyle(tint(for: provider))
                            .accessibilityHidden(true)
                    }
                    if let detail = provider.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                if state.loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading \(provider.label) usage")
                } else if let date = state.updatedAt, state.error == nil {
                    Text(date.formatted(date: .omitted, time: .standard))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .help("Last checked")
                }
                Link(destination: provider.dashboard) { Image(systemName: "arrow.up.right.square") }
                    .help("Open \(provider.name) usage dashboard")
                    .accessibilityLabel("Open \(provider.name) usage dashboard")
            }
            ForEach(state.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.id).foregroundStyle(.secondary)
                        Spacer()
                        if window.exceedsLimit, let reported = window.reportedPercent {
                            Label {
                                Text("\(reported, specifier: "%.0f")% used").monospacedDigit()
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            .help("Usage is over the limit")
                        } else if let percent = window.usedPercent {
                            Text("\(percent, specifier: "%.0f")% used").monospacedDigit()
                        } else { Text("Unavailable").foregroundStyle(.secondary) }
                    }.font(.subheadline)
                    if let percent = window.usedPercent {
                        ProgressView(value: percent, total: 100)
                            .tint(tint(for: provider))
                            .accessibilityLabel("\(provider.label), \(window.id)")
                            .accessibilityValue(window.exceedsLimit
                                ? "\(Int((window.reportedPercent ?? percent).rounded())) percent used, over the limit"
                                : "\(Int(percent.rounded())) percent used")
                    }
                    if let reset = window.resetsAt {
                        Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let date = state.updatedAt, state.error != nil {
                Text("Last successful check \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if state.loading && state.updatedAt == nil {
                Text("Checking subscription…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tint(for provider: Provider) -> Color {
        switch provider.kind {
        case .claude: Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255)
        case .codex: .blue
        case .antigravity: .indigo
        }
    }
}
