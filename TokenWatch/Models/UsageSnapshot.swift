import Foundation

/// Un relevé ponctuel des limites d'usage Claude, tel que renvoyé par
/// `GET /api/oauth/usage`.
///
/// `rawJSON` est conservé volontairement pendant la phase de spike (Phase 0) :
/// on ne connaît pas encore la forme exacte de la réponse, donc on garde le
/// corps brut pour finaliser le mapping des champs une fois une vraie réponse
/// capturée.
struct UsageSnapshot: Codable, Equatable {
    /// Utilisation de la fenêtre glissante 5 h, en pourcentage (0...100).
    var fiveHourPercent: Double?
    /// Utilisation de la fenêtre hebdomadaire, en pourcentage (0...100).
    var weeklyPercent: Double?
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?
    var fetchedAt: Date
    var rawJSON: String?

    static let empty = UsageSnapshot(fetchedAt: .distantPast)

    var hasData: Bool { fetchedAt != .distantPast }
}
