import Foundation

enum UsageClientError: Error, CustomStringConvertible {
    case http(status: Int, body: String)

    var description: String {
        switch self {
        case .http(let status, let body):
            if status == 401 { return "Non autorisé (401) — le token OAuth a peut-être expiré." }
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
        } catch UsageClientError.http(let status, _) where status == 401 {
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
            throw UsageClientError.http(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        return Self.parse(data)
    }

    // MARK: - Parsing (best-effort tant que la forme exacte n'est pas figée)

    /// Mapping défensif : on ne connaît pas encore les noms de champs exacts de
    /// la réponse, donc on scanne récursivement à la recherche d'un pourcentage
    /// d'utilisation, et on garde le JSON brut pour finaliser le mapping.
    static func parse(_ data: Data) -> UsageSnapshot {
        var snapshot = UsageSnapshot(fetchedAt: Date())
        snapshot.rawJSON = String(data: data, encoding: .utf8)

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
