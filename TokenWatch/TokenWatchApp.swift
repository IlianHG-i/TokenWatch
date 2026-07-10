import SwiftUI

/// TokenWatch — moniteur d'usage Claude dans la barre de menu macOS.
/// Le texte de la barre affiche le % de la fenêtre glissante 5 h ; le menu
/// déroulant montre le détail (5 h + hebdo) et permet un refresh manuel.
@main
struct TokenWatchApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
