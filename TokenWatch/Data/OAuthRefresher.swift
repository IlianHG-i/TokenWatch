import Foundation
import Security

/// Rafraîchit le token OAuth Claude quand l'access token a expiré.
///
/// Les access tokens Claude expirent ~toutes les heures, donc sans refresh
/// l'app tomberait en 401 en permanence. On réutilise le flux OAuth de Claude
/// Code : `POST /v1/oauth/token` (grant_type=refresh_token) avec le `client_id`
/// public de Claude Code, puis on réécrit les identifiants dans le trousseau.
enum OAuthRefresher {
    /// client_id public de Claude Code (présent dans le binaire du CLI).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://api.anthropic.com/v1/oauth/token")!

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// Échange le refresh token contre un nouvel access token, persiste le
    /// résultat dans le trousseau et renvoie les identifiants à jour.
    static func refresh(using current: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = current.refreshToken else {
            throw KeychainReaderError.notFound
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UsageClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAtMs = token.expiresIn.map { Date().timeIntervalSince1970 * 1000 + $0 * 1000 }
        try KeychainWriter.writeCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAtMs: expiresAtMs
        )
        return try KeychainReader.readCredentials()
    }
}

/// Réécrit les identifiants OAuth dans le trousseau au format attendu par
/// Claude Code (`{"claudeAiOauth":{…}}`).
enum KeychainWriter {
    static func writeCredentials(accessToken: String, refreshToken: String, expiresAtMs: Double?) throws {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
        ]
        if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
        let payload = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])

        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainReader.service,
        ]
        let update: [String: Any] = [kSecValueData as String: payload]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw KeychainReaderError.status(status) }
    }
}
