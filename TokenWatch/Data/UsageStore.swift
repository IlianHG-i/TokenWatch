import Foundation
import SwiftUI

/// Orchestre le rafraîchissement de l'usage.
///
/// Stratégie « événementiel d'abord » (cf. CLAUDE.md) :
/// 1. refresh immédiat au lancement ;
/// 2. refresh déclenché par FSEvents quand Claude Code écrit sur le disque
///    (avec un plancher de 10 s entre deux appels, cf. `minAutoRefreshGap`) ;
/// 3. timer de secours réglable (30 s à 20 min, défaut 2 min 30) comme filet.
///
/// Le filet couvre aussi l'usage via Claude Desktop / claude.ai, qui ne
/// touchent pas `~/.claude/projects` et ne déclenchent donc pas (2) — la
/// limite affichée reste exacte dans tous les cas (l'endpoint `/api/oauth/usage`
/// est au niveau du compte, pas du client), seul le délai de mise à jour varie.
///
/// Sur 429 (trop de requêtes), aucun nouvel appel réseau n'est tenté avant la
/// fin du cooldown (`Retry-After` du serveur, ou 60 s par défaut).
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshInterval: TimeInterval

    private let client = UsageClient()
    private var watcher: ActivityWatcher?
    private var fallbackTimer: Timer?

    /// Plage réglable du timer de secours : 30 s (profil réactif) à 20 min
    /// (profil économique). Le refresh événementiel (FSEvents) n'est pas
    /// affecté par ce réglage.
    static let refreshIntervalRange: ClosedRange<TimeInterval> = 30...1200
    static let defaultRefreshInterval: TimeInterval = 150
    private static let refreshIntervalDefaultsKey = "refreshIntervalSeconds"

    /// Plancher entre deux appels réseau déclenchés par les événements FSEvents
    /// (indépendant du debounce du watcher, qui ne fait que coalescer les
    /// rafales sur 2,5 s). Sans ce plancher, une session Claude Code très
    /// active — dont les propres logs vivent dans `~/.claude/projects`,
    /// surveillé par l'app — peut déclencher un refresh toutes les
    /// quelques secondes en continu et finir par se faire limiter (HTTP 429).
    private static let minAutoRefreshGap: TimeInterval = 10
    private var lastAttemptAt: Date = .distantPast
    /// Renseigné après un 429 : aucun nouvel appel réseau avant cette date,
    /// y compris pour les refresh automatiques déclenchés entre-temps.
    private var rateLimitedUntil: Date?
    /// Nombre de 429 consécutifs (remis à zéro dès qu'un refresh réussit) —
    /// alimente le backoff exponentiel ci-dessous.
    private var consecutiveRateLimitCount = 0
    private static let baseRateLimitBackoff: TimeInterval = 60
    private static let maxRateLimitBackoff: TimeInterval = 600

    private var projectsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.refreshIntervalDefaultsKey)
        refreshInterval = Self.refreshIntervalRange.contains(stored) ? stored : Self.defaultRefreshInterval
        start()
    }

    func start() {
        Task { await refresh() }

        let watcher = ActivityWatcher(path: projectsPath) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher

        scheduleFallbackTimer()
    }

    /// Change l'intervalle du timer de secours (persisté, appliqué immédiatement).
    func setRefreshInterval(_ seconds: TimeInterval) {
        let clamped = min(max(seconds, Self.refreshIntervalRange.lowerBound), Self.refreshIntervalRange.upperBound)
        refreshInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.refreshIntervalDefaultsKey)
        scheduleFallbackTimer()
    }

    private func scheduleFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// - Parameter force: ignore le plancher anti-martèlement (utilisé par le
    ///   bouton "Rafraîchir" manuel). Le cooldown après un 429 s'applique
    ///   toujours, même en mode forcé, pour ne jamais aggraver une limitation
    ///   déjà en cours.
    func refresh(force: Bool = false) async {
        if let until = rateLimitedUntil {
            guard Date() >= until else {
                lastError = String(describing: UsageClientError.http(
                    status: 429, body: "", retryAfter: until.timeIntervalSinceNow))
                return
            }
            rateLimitedUntil = nil
        }

        guard !isRefreshing else { return }
        if !force {
            guard Date().timeIntervalSince(lastAttemptAt) >= Self.minAutoRefreshGap else { return }
        }
        lastAttemptAt = Date()
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await client.fetch()
            lastError = nil
            consecutiveRateLimitCount = 0
        } catch UsageClientError.http(let status, _, let retryAfter) where status == 429 {
            consecutiveRateLimitCount += 1
            // Le serveur peut renvoyer `Retry-After: 0` (observé en pratique),
            // ce qui ne veut rien dire — un `retryAfter ?? 60` s'y ferait
            // piéger (0 n'est pas nil) et annulerait tout backoff. On ignore
            // les valeurs non exploitables et on applique un backoff
            // exponentiel maison (60 s, 120 s, 240 s… plafonné à 10 min).
            let serverHint = (retryAfter ?? 0) > 1 ? retryAfter : nil
            let backoff = serverHint ?? min(
                Self.baseRateLimitBackoff * pow(2, Double(consecutiveRateLimitCount - 1)),
                Self.maxRateLimitBackoff
            )
            rateLimitedUntil = Date().addingTimeInterval(backoff)
            lastError = String(describing: UsageClientError.http(status: 429, body: "", retryAfter: backoff))
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Texte de la barre de menu : 5 h et hebdo côte à côte, séparés par « | ».
    var menuBarText: String {
        let five = snapshot.fiveHourPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        let weekly = snapshot.weeklyPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "\(five)|\(weekly)"
    }
}
