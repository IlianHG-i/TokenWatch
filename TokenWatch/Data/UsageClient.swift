import Foundation

enum UsageClientError: Error, CustomStringConvertible {
    case http(status: Int, body: String, retryAfter: TimeInterval?)

    var description: String {
        switch self {
        case .http(let status, let body, let retryAfter):
            if status == 401 { return "Non autorisé (401) — le token OAuth a peut-être expiré." }
            if status == 429 {
                let delay = Int((retryAfter ?? 60).rounded())
                return "Trop de requêtes (429) — nouvelle tentative dans \(delay) s."
            }
            return "HTTP \(status): \(body.prefix(200))"
        }
    }
}

/// Interroge l'endpoint d'usage officiel de Claude avec le token OAuth du
/// trousseau. C'est la source primaire du pourcentage affiché.
struct UsageClient {
    var credentialsProvider: () throws -> ClaudeCredentials = { try KeychainReader.readCredentials() }
    var endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> UsageSnapshot {
        var creds = try credentialsProvider()

        // Refresh proactif si le token est déjà expiré (les tokens Claude
        // expirent ~toutes les heures).
        if creds.isExpired {
            creds = try await OAuthRefresher.refresh(using: creds)
        }

        do {
            return try await get(with: creds.accessToken)
        } catch UsageClientError.http(let status, _, _) where status == 401 {
            // Filet : token invalidé côté serveur → un refresh + retry unique.
            let refreshed = try await OAuthRefresher.refresh(using: creds)
            return try await get(with: refreshed.accessToken)
        }
    }

    private func get(with accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("TokenWatch/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageClientError.http(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "",
                                        retryAfter: retryAfter)
        }
        return Self.parse(data)
    }

    // MARK: - Parsing

    /// Schéma réel de `GET /api/oauth/usage` (capturé sur une réponse 200).
    /// `utilization` est déjà un pourcentage 0...100 ; `resets_at` est une
    /// date ISO-8601 avec fraction de secondes.
    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        let five_hour: Window?
        let seven_day: Window?
    }

    /// Décodage typé du schéma connu ; repli sur un scan heuristique si la forme
    /// change (`rawJSON` conservé pour diagnostic).
    static func parse(_ data: Data) -> UsageSnapshot {
        var snapshot = UsageSnapshot(fetchedAt: Date())
        snapshot.rawJSON = String(data: data, encoding: .utf8)

        if let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data),
           decoded.five_hour != nil || decoded.seven_day != nil {
            snapshot.fiveHourPercent = decoded.five_hour?.utilization
            snapshot.weeklyPercent = decoded.seven_day?.utilization
            snapshot.fiveHourResetsAt = decoded.five_hour?.resets_at.flatMap(parseISO)
            snapshot.weeklyResetsAt = decoded.seven_day?.resets_at.flatMap(parseISO)
            return snapshot
        }

        return heuristicParse(data, into: snapshot)
    }

    private static func parseISO(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    // MARK: - Repli heuristique (si le schéma évolue)

    private static func heuristicParse(_ data: Data, into snapshot: UsageSnapshot) -> UsageSnapshot {
        var snapshot = snapshot
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return snapshot }
        var percents: [(path: String, percent: Double)] = []
        var resets: [(path: String, date: Date)] = []
        collect(root, path: "", percents: &percents, resets: &resets)

        let fiveHourNeedles = ["five_hour", "five hour", "5h", "session", "hour"]
        let weeklyNeedles = ["seven_day", "seven day", "7d", "week", "weekly"]

        snapshot.fiveHourPercent = firstMatch(percents, needles: fiveHourNeedles)
        snapshot.weeklyPercent = firstMatch(percents, needles: weeklyNeedles)
        snapshot.fiveHourResetsAt = firstMatch(resets, needles: fiveHourNeedles)
        snapshot.weeklyResetsAt = firstMatch(resets, needles: weeklyNeedles)
        return snapshot
    }

    private static func collect(_ node: Any, path: String,
                                percents: inout [(path: String, percent: Double)],
                                resets: inout [(path: String, date: Date)]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                let childPath = (path.isEmpty ? key : "\(path).\(key)").lowercased()
                if isPercentKey(key), let number = numeric(value) {
                    percents.append((childPath, normalize(number)))
                }
                if isResetKey(key), let date = date(from: value) {
                    resets.append((childPath, date))
                }
                collect(value, path: childPath, percents: &percents, resets: &resets)
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() {
                collect(value, path: "\(path)[\(index)]", percents: &percents, resets: &resets)
            }
        }
    }

    private static func isPercentKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.contains("utilization") || k.contains("percent") || k.contains("used") || k.contains("usage")
    }

    private static func isResetKey(_ key: String) -> Bool {
        key.lowercased().contains("reset")
    }

    private static func numeric(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// Ramène une valeur 0...1 à 0...100 si nécessaire.
    private static func normalize(_ value: Double) -> Double {
        value <= 1.0 ? value * 100 : value
    }

    /// Parse une date de reset : ISO-8601 (`resets_at`) ou epoch (s / ms).
    private static func date(from value: Any) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = numeric(value) {
            // Heuristique s vs ms.
            return Date(timeIntervalSince1970: n > 3_000_000_000 ? n / 1000 : n)
        }
        return nil
    }

    private static func firstMatch<T>(_ items: [(path: String, T)], needles: [String]) -> T? {
        items.first { item in needles.contains { item.path.contains($0) } }?.1
    }
}
