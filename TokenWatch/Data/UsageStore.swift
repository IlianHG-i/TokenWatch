import Foundation
import SwiftUI

/// Orchestre le rafraîchissement de l'usage.
///
/// Stratégie « événementiel d'abord » (cf. CLAUDE.md) :
/// 1. refresh immédiat au lancement ;
/// 2. refresh déclenché par FSEvents quand Claude écrit sur le disque ;
/// 3. timer de secours lent (20 min) comme filet.
/// Au repos : aucune requête réseau.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let client = UsageClient()
    private var watcher: ActivityWatcher?
    private var fallbackTimer: Timer?

    private var projectsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    init() {
        start()
    }

    func start() {
        Task { await refresh() }

        let watcher = ActivityWatcher(path: projectsPath) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await client.fetch()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    var menuBarText: String {
        guard let percent = snapshot.fiveHourPercent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }
}
