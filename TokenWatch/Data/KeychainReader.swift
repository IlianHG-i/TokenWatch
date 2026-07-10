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
    /// `root`, et une valide sous le compte utilisateur courant).
    ///
    /// ⚠️ Sur macOS, combiner `kSecReturnData` + `kSecReturnAttributes` +
    /// `kSecMatchLimitAll` dans une seule requête `SecItemCopyMatching` échoue
    /// systématiquement avec `errSecParam` (-50) — limitation du framework,
    /// pas un souci de droits. On évite donc ce combo : requête ciblée sur le
    /// compte courant en premier, puis repli en deux temps (liste des
    /// attributs seuls, puis data d'un item précis via sa référence
    /// persistante) si aucune entrée n'existe pour ce compte.
    static func readCredentials() throws -> ClaudeCredentials {
        if let mine = try? readData(account: NSUserName()) {
            return mine
        }
        return try readAnyAccount()
    }

    private static func readData(account: String) throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw KeychainReaderError.status(status) }
        guard let data = item as? Data else { throw KeychainReaderError.malformed }
        return try JSONDecoder().decode(ClaudeCredentials.self, from: data)
    }

    /// Repli : liste toutes les entrées (attributs + référence persistante,
    /// sans données secrètes — pas de -50), puis récupère la donnée de la
    /// première entrée exploitable.
    private static func readAnyAccount() throws -> ClaudeCredentials {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? KeychainReaderError.notFound
                : KeychainReaderError.status(status)
        }
        guard let items = result as? [[String: Any]], !items.isEmpty else {
            throw KeychainReaderError.notFound
        }

        for item in items {
            guard let persistentRef = item[kSecValuePersistentRef as String] else { continue }
            let dataQuery: [String: Any] = [
                kSecValuePersistentRef as String: persistentRef,
                kSecReturnData as String: true,
            ]
            var dataResult: CFTypeRef?
            guard SecItemCopyMatching(dataQuery as CFDictionary, &dataResult) == errSecSuccess,
                  let data = dataResult as? Data,
                  let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
            else { continue }
            return creds
        }
        throw KeychainReaderError.malformed
    }
}
