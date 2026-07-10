# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> État : dépôt greenfield. Le projet Xcode n'est pas encore scaffoldé — ce fichier
> documente la vision, la stack cible et surtout la **couche données** (la partie
> non triviale qui demande de lire plusieurs sources). Repo : https://github.com/IlianHG-i/TokenWatch

## Objectif produit

**TokenWatch** est une app macOS légère qui affiche l'usage/la limite Claude en temps réel :

- **Menu bar** : pourcentage d'usage affiché en permanence (`MenuBarExtra`).
- **Fenêtre app** : vue détaillée (fenêtres 5 h / hebdo, historique de conso, breakdown par jour/projet/modèle).
- **Widgets macOS** (`WidgetKit`) : jauges d'usage sur le bureau / centre de notifications.

## Stack cible

- **Swift + SwiftUI**, natif. Xcode 26.x est installé (`xcodebuild -version`).
- `MenuBarExtra` (menu bar), `WidgetKit` + `App Intents` (widgets), Swift Concurrency (`async/await`) pour le polling réseau et le parsing.
- **App group partagé** (`group.<bundle-id>`) obligatoire : le widget est un process séparé et doit lire les données via l'app group (UserDefaults suite partagée ou fichier partagé), pas via l'état mémoire de l'app principale.

## Couche données — le cœur du projet

Il y a **deux sources indépendantes**. Ne pas les confondre : l'une donne la *limite officielle*, l'autre le *détail des tokens*.

### 1. Limite officielle (source primaire — c'est le « pourcentage » que veut l'utilisateur)

- **Endpoint** : `GET https://api.anthropic.com/api/oauth/usage`
  - En-tête : `Authorization: Bearer <accessToken>`.
  - C'est exactement la donnée qu'affiche la commande `/usage` de Claude Code : utilisation de la fenêtre glissante **5 h** (session) et de la fenêtre **hebdomadaire**.
- **Token OAuth** : stocké dans le **Keychain macOS**, service `Claude Code-credentials`.
  - JSON : `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-…","refreshToken":"sk-ant-ort01-…","expiresAt":…}}`.
  - Lecture : `security find-generic-password -s "Claude Code-credentials" -w`, ou l'API `Security.framework` (`SecItemCopyMatching`) en Swift.
  - **Le token expire** : gérer le rafraîchissement via `refreshToken` (endpoint OAuth token) quand `expiresAt` est dépassé, sinon l'endpoint usage renvoie 401.
- **En-têtes rate-limit temps réel** (contexte, source secondaire) : les réponses de `/v1/messages` portent des en-têtes `anthropic-ratelimit-unified-*` (`-status`, `-reset`, `-fallback`, `-overage-*`…). Utiles pour comprendre le modèle de quota, mais **non exploitables pour un moniteur passif** (il faut émettre une requête). Le moniteur doit donc s'appuyer sur `/api/oauth/usage`.

### 2. Détail des tokens (source secondaire — vue historique / breakdown)

- **Fichiers** : `~/.claude/projects/**/*.jsonl` (un fichier JSONL par session ; une ligne par événement).
- Chaque message assistant contient un objet `usage` :
  `{"input_tokens":…, "cache_creation_input_tokens":…, "cache_read_input_tokens":…, "output_tokens":…, "server_tool_use":{…}}`.
- Approche **ccusage-like** : parser les lignes, sommer par jour / projet / modèle, appliquer la grille tarifaire par modèle pour estimer le coût. C'est ce qui alimente l'historique et les graphes de la vue détaillée.
- Le nom de dossier encode le chemin projet (slashes remplacés par des tirets), ex. `-Users-macbookair-…`.
- Agrégats déjà pré-calculés disponibles : `~/.claude/stats-cache.json` (`dailyActivity`: messageCount / sessionCount / toolCallCount par date) — pratique pour un affichage rapide sans re-parser tout le JSONL.

## Contraintes techniques à garder en tête

- **Sandbox / entitlements** : lire le Keychain et `~/.claude/**` impose des choix. Le partage Keychain via app group + entitlement `keychain-access-groups`, et l'accès fichiers hors container, doivent être testés tôt — c'est le principal risque d'architecture. Si le sandbox bloque, envisager une app non-sandboxée (distribution hors App Store) plutôt que de contourner.
- **Ne jamais logguer ni committer le token OAuth** (`sk-ant-oat01-…` / `sk-ant-ort01-…`).
- **Rafraîchissement / polling** : poll de `/api/oauth/usage` à intervalle raisonnable (respecter les fenêtres de reset renvoyées ; ne pas marteler l'API). Le widget lit le dernier snapshot via l'app group, il ne fait pas d'appel réseau lui-même.

## Build / run

Le projet Xcode n'existe pas encore. Une fois scaffoldé (`TokenWatch.xcodeproj` ou package SwiftPM + target app) :

```bash
# Build en ligne de commande
xcodebuild -scheme TokenWatch -configuration Debug build
# Tests
xcodebuild -scheme TokenWatch test
# Un seul test
xcodebuild -scheme TokenWatch test -only-testing:TokenWatchTests/<Suite>/<testMethod>
```

Au quotidien, développer dans Xcode (⌘R pour lancer l'app + la menu bar ; les widgets se testent via le scheme du widget extension et l'app Xcode Previews).
