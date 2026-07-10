# TokenWatch

App macOS légère qui affiche l'usage/la limite Claude en temps réel : pourcentage
dans la barre de menu, vue détaillée dans l'app, et widgets sur le bureau.

> Repo : https://github.com/IlianHG-i/TokenWatch — Xcode 26+ / Swift 5+ / macOS 14+

## État actuel — Phase 1 (menu bar MVP)

- ✅ Barre de menu (`MenuBarExtra`) affichant le % de la fenêtre glissante 5 h.
- ✅ Lecture du token OAuth Claude dans le trousseau (`Claude Code-credentials`).
- ✅ Appel de l'endpoint d'usage officiel `GET /api/oauth/usage`.
- ✅ Refresh OAuth automatique sur token expiré (`POST /v1/oauth/token`).
- ✅ Rafraîchissement **événementiel** via FSEvents sur `~/.claude/projects`
  (0 requête au repos) + timer de secours 20 min.

À suivre : figer le mapping exact de la réponse `/api/oauth/usage` (voir ci-dessous),
puis Phase 2 (vue détaillée / historique JSONL) et Phase 3 (widgets). Feuille de
route complète dans `CLAUDE.md`.

## Build & run

```bash
# Ouvrir dans Xcode (recommandé pour lancer l'app menu bar)
open TokenWatch.xcodeproj

# Build en ligne de commande
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -destination 'platform=macOS' build
```

L'app tourne comme **agent** (`LSUIElement`) : pas d'icône dans le Dock, seulement
l'item dans la barre de menu.

## Architecture (résumé)

| Composant | Rôle |
|---|---|
| `Data/KeychainReader` | Lit le token OAuth Claude dans le trousseau macOS |
| `Data/OAuthRefresher` | Rafraîchit le token expiré et le réécrit dans le trousseau |
| `Data/UsageClient` | Appelle `/api/oauth/usage`, parse le %, retry sur 401 |
| `Data/ActivityWatcher` | FSEvents sur `~/.claude/projects`, callback debouncé |
| `Data/UsageStore` | Orchestration du refresh (événementiel + filet timer) |
| `UI/MenuContentView` | Menu déroulant : jauges 5 h / hebdo |

## ⚠️ Point ouvert : mapping de la réponse usage

Le parsing de `/api/oauth/usage` est **best-effort** (recherche récursive d'un
champ de pourcentage) tant qu'une vraie réponse 200 n'a pas été capturée — le
token de test était expiré au moment du scaffold. `UsageSnapshot.rawJSON`
conserve le corps brut pour figer les noms de champs exacts dès la première
réponse valide.

## Sécurité

Ne jamais logger ni committer les tokens (`sk-ant-oat01-…`, `sk-ant-ort01-…`).
L'app est non sandboxée pour lire le trousseau et `~/.claude` (cf. « Risque n°1 »
dans `CLAUDE.md`).
