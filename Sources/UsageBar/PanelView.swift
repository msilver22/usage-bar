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
                    .help("Refresh both subscriptions")
                    .accessibilityLabel("Refresh both subscriptions")
                    .disabled(store.states.values.contains { $0.loading })
                Button { store.showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Keyboard shortcut settings")
                    .accessibilityLabel("Keyboard shortcut settings")
            }
            ForEach(Service.allCases) { service in
                provider(service, state: store.states[service] ?? UsageState())
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

    private func provider(_ service: Service, state: UsageState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Text(service.rawValue).font(.headline)
                    Image(nsImage: Bundle.module.image(forResource: NSImage.Name(service.rawValue))!)
                        .renderingMode(service == .codex ? .template : .original)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipped()
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
                Spacer()
                if state.loading { ProgressView().controlSize(.small).accessibilityLabel("Loading \(service.rawValue) usage") }
                Link(destination: service.dashboard) { Image(systemName: "arrow.up.right.square") }
                    .help("Open \(service.rawValue) usage dashboard")
                    .accessibilityLabel("Open \(service.rawValue) usage dashboard")
            }
            ForEach(state.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.id).foregroundStyle(.secondary)
                        Spacer()
                        if let percent = window.usedPercent {
                            Text("\(percent, specifier: "%.0f")% used").monospacedDigit()
                        } else { Text("Unavailable").foregroundStyle(.secondary) }
                    }.font(.subheadline)
                    if let percent = window.usedPercent {
                        ProgressView(value: percent, total: 100)
                            .tint(service == .claude ? Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255) : .blue)
                            .accessibilityLabel("\(service.rawValue), \(window.id)")
                            .accessibilityValue("\(Int(percent.rounded())) percent used")
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
            if let date = state.updatedAt {
                Text("\(state.error == nil ? "Checked" : "Last successful check") \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if state.loading {
                Text("Checking subscription…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
