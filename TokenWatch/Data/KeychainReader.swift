import Foundation
import Security

enum KeychainReaderError: Error, CustomStringConvertible {
    case notFound
    case malformed
    case status(OSStatus)

    var description: String {
        switch self {
        case .notFound:
            return "Identifiants Claude introuvables dans le trousseau (service « Claude Code-credentials »). Es-tu connecté dans Claude Code ?"
        case .malformed:
            return "Données du trousseau illisibles."
        case .status(let s):
            return "Erreur trousseau (OSStatus \(s))."
        }
    }
}

/// Identifiants OAuth que Claude Code stocke dans le trousseau macOS
/// (service générique « Claude Code-credentials »), au format :
/// `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-…","refreshToken":"…","expiresAt":…}}`.
struct ClaudeCredentials: Decodable {
    let accessToken: String
    let refreshToken: String?
    /// Expiration en millisecondes depuis epoch (convention Claude Code).
    let expiresAt: Double?

    private enum RootKeys: String, CodingKey { case claudeAiOauth }
    private enum OAuthKeys: String, CodingKey { case accessToken, refreshToken, expiresAt }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let oauth = try root.nestedContainer(keyedBy: OAuthKeys.self, forKey: .claudeAiOauth)
        accessToken = try oauth.decode(String.self, forKey: .accessToken)
        refreshToken = try oauth.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try oauth.decodeIfPresent(Double.self, forKey: .expiresAt)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 * 1000 >= expiresAt
    }
}

enum KeychainReader {
    static let service = "Claude Code-credentials"

    /// Lit les identifiants OAuth depuis le trousseau. Nécessite que l'app
    /// tourne sous le même utilisateur que Claude Code (non sandboxée pour
    /// l'instant — cf. « Risque n°1 » dans CLAUDE.md).
    ///
    /// Il peut exister **plusieurs** entrées pour le même service (p. ex. une
    /// périmée créée un jour où `claude` a tourné en `sudo`, sous le compte
    /// `root`, et une valide sous le compte utilisateur courant). On les
    /// récupère toutes et on garde la meilleure : compte courant en priorité,
    /// sinon la date d'expiration la plus lointaine.
    static func readCredentials() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? KeychainReaderError.notFound
                : KeychainReaderError.status(status)
        }
        guard let items = result as? [[String: Any]] else { throw KeychainReaderError.malformed }

        let currentUser = NSUserName()
        let candidates: [(account: String?, creds: ClaudeCredentials)] = items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data,
                  let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
            else { return nil }
            return (item[kSecAttrAccount as String] as? String, creds)
        }
        guard !candidates.isEmpty else { throw KeychainReaderError.malformed }

        // 1) entrée du compte courant si présente ; 2) sinon la moins expirée.
        if let mine = candidates.first(where: { $0.account == currentUser }) {
            return mine.creds
        }
        return candidates.max { ($0.creds.expiresAt ?? 0) < ($1.creds.expiresAt ?? 0) }!.creds
    }
}
