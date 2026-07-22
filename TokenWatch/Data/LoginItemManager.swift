import Foundation
import ServiceManagement

/// Enregistre/désenregistre TokenWatch comme élément de connexion macOS via
/// l'API moderne `SMAppService` (pas de helper séparé nécessaire).
///
/// ⚠️ Ce mécanisme pointe vers le chemin exact du `.app` au moment de
/// l'enregistrement. Si le bundle est reconstruit ailleurs (ex. nouveau
/// dossier DerivedData), l'entrée devient obsolète — d'où l'intérêt d'un
/// emplacement stable (`/Applications`) pour un usage au quotidien.
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Retourne `true` en cas de succès. Les échecs (rares : bundle non
    /// signé, restriction système) sont silencieux côté appelant — l'état
    /// affiché reflète toujours `isEnabled` après coup.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
