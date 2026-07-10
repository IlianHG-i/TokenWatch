import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TokenWatch").font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            gauge("Fenêtre 5 h", store.snapshot.fiveHourPercent, reset: store.snapshot.fiveHourResetsAt)
            gauge("Hebdomadaire", store.snapshot.weeklyPercent, reset: store.snapshot.weeklyResetsAt)

            if let error = store.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if store.snapshot.hasData {
                Text("Maj \(store.snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rafraîchissement auto").font(.caption)
                    Spacer()
                    Text(formattedInterval(store.refreshInterval))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { store.refreshInterval },
                        set: { store.setRefreshInterval($0) }
                    ),
                    in: UsageStore.refreshIntervalRange,
                    step: 10
                )
                Text("30 s (réactif) → 20 min (économique)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Rafraîchir") { Task { await store.refresh() } }
                if store.snapshot.rawJSON != nil {
                    Button("Copier JSON") { copyRawJSON() }
                        .help("Copie la réponse brute de /api/oauth/usage (pour figer le mapping des champs)")
                }
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private func gauge(_ title: String, _ percent: Double?, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.subheadline.monospacedDigit()).bold()
            }
            ProgressView(value: min(max((percent ?? 0) / 100, 0), 1))
                .tint(color(for: percent))
            if let reset {
                Text("reset \(reset.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for percent: Double?) -> Color {
        switch percent ?? 0 {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    private func copyRawJSON() {
        guard let raw = store.snapshot.rawJSON else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    private func formattedInterval(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total) s" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s"
    }
}
