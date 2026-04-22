# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, quotas 5h/7j avec calcul de cout reel depuis les logs JSONL.

## Preview

```
Opus 4.7 (1M context) ▌▌▌▌▌ │ my-project │ * main +2 ~1 ?3 │ v2.1.75 ●
██████░░░░░░░░░ 40% │ $1.24 │ +45 -12 │ 3m 22s │ NORMAL 20h-14h ██████░░ 3h19
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▰▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50
```

## Fonctionnalites

**Ligne 1 — Identite & Git**
- Nom du modele avec couleur (Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **⚡** (jaune) si le fast mode est actif
- Indicateur **effort level** en barres verticales (detection live via `<local-command-stdout>` dans le JSONL de session), adapte au modele :
  - **Sonnet / Opus 4.5 / Opus 4.6** (4 barres) : `▌░░░` low (cyan) → `▌▌░░` medium (jaune) → `▌▌▌░` high (rouge) → `▌▌▌▌` max (magenta)
  - **Opus 4.7** (5 barres) : ajoute `▌▌▌▌░` xhigh (orange) entre high et max
  - **Haiku** : pas d'indicateur (le modele n'a pas de niveau d'effort)
- Nom du sub-agent (si applicable)
- Mode vim (`[N]`/`[I]`)
- Nom du projet courant
- Branche git avec fichiers staged (`+`), modifies (`~`), et untracked (`?`)
- Version de Claude Code
- Indicateur **status Claude** via [status.claude.com](https://status.claude.com) (API `summary.json`, cache 60s) :
  - `●` vert — Operational
  - `●` jaune — Degraded Performance
  - `●` orange — Partial Outage
  - `●` rouge — Major Outage
  - `●` bleu — Maintenance

**Ligne 2 — Contexte & Session**
- Barre de progression du contexte avec seuils de couleur (vert < 70%, jaune < 90%, rouge >= 90%)
- Cout de la session courante (USD)
- Lignes ajoutees/supprimees
- Duree de la session
- **Indicateur peak/off-peak** — heures de pointe Anthropic (lun-ven 13h-19h UTC) :
  - `NORMAL` (terracotta) — off-peak, limites 5h normales
  - `NERFED` (gris) — peak, limites 5h consommees plus vite
  - `WEEKEND` (terracotta) — off-peak tout le weekend
  - Barre de progression + countdown vers la prochaine transition
  - Couleurs inspirees de [is-claude-nerfed-right-now.vercel.app](https://is-claude-nerfed-right-now.vercel.app/)

**Ligne 3 — Quotas d'utilisation**
- Quota 5 heures : mini-barre + pourcentage + timer avant reset + **cout 5h**
- Quota 7 jours : mini-barre + pourcentage + timer avant reset + **cout hebdo reel**
- Donnees recuperees via l'API OAuth Anthropic (cache 300s, backoff 429 10min, flock multi-instances)

## Calcul des couts

Les couts (5h et hebdo) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API.

### Prix (USD / MTok) — Avril 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Opus 4.5 / 4.6 / 4.7** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.6 Fast** | $30 | $150 | $37.50 | $60 | $3 |
| **Sonnet 4.6** | $3 | $15 | $3.75 | $6 | $0.30 |
| **Haiku 4.5** | $1 | $5 | $1.25 | $2 | $0.10 |
| Opus legacy | $15 | $75 | $18.75 | $30 | $1.50 |

> Fast mode est disponible uniquement sur Opus 4.6 (pas sur 4.7).

### Session semaine alignee sur Anthropic

Le script persiste le debut de la fenetre hebdomadaire dans `~/.claude/week-session` pour eviter les derives du `resets_at` (API rolling). La fenetre ne se recalcule que lorsque la session expire reellement (`now >= resets_at`).

### Fast mode

Le fast mode (x6 sur tous les prix) est detecte de deux manieres :
- **Affichage ⚡** : lit `fastMode` dans `~/.claude/settings.json` (session courante)
- **Calcul cout** : lit le champ `speed` de chaque requete dans les JSONL (historique precis)

### Indicateur peak/off-peak

Anthropic ajuste les limites de session 5h pendant les heures de pointe ([source](https://x.com/trq212)). Le script detecte automatiquement la fenetre active :

| Etat | Condition (Pacific Time) | Couleur |
|---|---|---|
| **NORMAL** | Lun-ven hors 5h-11h PT | Terracotta (`#cc785c`) |
| **NERFED** | Lun-ven 5h-11h PT | Gris mute (`#828179`) |
| **WEEKEND** | Ven 11h PT → lun 5h PT | Terracotta |

- Reference Pacific Time (suit le DST US automatiquement via `TZ`)
- Heures affichees en timezone locale (ex: 14h-20h CEST/CET)
- Barre de progression 8 blocs dans la fenetre courante
- Countdown vers la prochaine transition
- Couleurs inspirees de [is-claude-nerfed-right-now.vercel.app](https://is-claude-nerfed-right-now.vercel.app/)

### Thinking tokens

Les thinking tokens sont inclus dans `output_tokens` sur le dernier chunk de streaming. Pas besoin de les compter separement.

## Installation

### Installation rapide (recommandee)

Un installer cross-platform detecte l'OS et fait tout le necessaire :

```bash
npx github:jeremywtp/statusline-claude-code
```

Prerequis : Node 18+. L'installer :

- copie `statusline.sh` vers `~/.claude/statusline.sh` (avec backup `.bak` horodate si un script existant est present)
- merge proprement la cle `statusLine` dans `~/.claude/settings.json` sans casser les autres cles (`env`, `permissions`, `enabledPlugins`, etc.)
- verifie / installe les dependances (`jq`, `curl`, `git`)
- applique le **patch macOS complet** (voir plus bas) si OS = Darwin

### Linux / WSL2

Dependances attendues : `jq`, `curl`, `git`, `bash 4+`. L'installer refuse de continuer si l'une manque et propose la commande apt/pacman/dnf adaptee.

```bash
npx github:jeremywtp/statusline-claude-code
```

### macOS (Intel + Apple Silicon)

Le script d'origine utilise des commandes GNU incompatibles BSD (`stat -c`, `date -d`, `md5sum`, `grep -oP`, `flock`, et depend de Bash 5+). L'installer macOS :

1. verifie Homebrew (refuse si absent et renvoie la commande d'install Homebrew)
2. detecte Apple Silicon (`/opt/homebrew`) ou Intel (`/usr/local`)
3. `brew install coreutils findutils grep bash jq curl git` pour ce qui manque seulement
4. insere un **shim de compatibilite** dans `statusline.sh` qui redirige `stat`/`date`/`md5sum`/`grep`/`find`/`flock` vers leurs equivalents GNU (`gstat`, `gdate`, `gmd5sum`, `ggrep`, `gfind`) et stub `flock` (inexistant sur macOS)
5. reecrit le shebang vers Bash 5+ Homebrew (macOS livre `/bin/bash` en 3.2)

Prerequis : avoir [Homebrew](https://brew.sh) installe (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`).

```bash
npx github:jeremywtp/statusline-claude-code
```

### Windows

Pas de support natif (Claude Code et ses scripts bash ne tournent pas sur `cmd`/PowerShell). Installer [WSL2](https://learn.microsoft.com/fr-fr/windows/wsl/install) et lancer la commande depuis Ubuntu.

### Commandes disponibles

```bash
# Install / update (re-run pour mettre a jour)
npx github:jeremywtp/statusline-claude-code

# Diagnostic : OS, dependances, fichiers, credentials
npx github:jeremywtp/statusline-claude-code doctor

# Desinstallation (retire statusline.sh et la cle statusLine)
npx github:jeremywtp/statusline-claude-code uninstall

# Options
#   --no-backup   n'ecrit pas de .bak des fichiers modifies
```

### Installation manuelle (fallback)

Si l'installer npx ne convient pas, voir `bin/platforms/linux.mjs` et `bin/shims/macos.sh` pour les etapes exactes — ou simplement :

```bash
cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
```

Puis ajouter dans `~/.claude/settings.json` :

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

> Sur macOS, il faut **en plus** installer `coreutils findutils grep bash` via Homebrew et injecter le shim `bin/shims/macos.sh` apres `set -euo pipefail` — l'installer npx gere tout ca automatiquement.

## Fichiers et cache

| Fichier | Description | TTL |
|---|---|---|
| `~/.claude/statusline.sh` | Script principal | — |
| `~/.claude/settings.json` | Config Claude Code (statusLine) | — |
| `~/.claude/week-session` | Persistance fenetre hebdo (`resets_at\|WEEK_START`) | Jusqu'au reset |
| `~/.claude/usage-session` | Persistance durable API usage (%, timers) — fallback si cache /tmp vide | Jusqu'au prochain succes API |
| `/tmp/claude-sl-usage-cache` | Cache API OAuth (quotas + couts 5h/7j, 7 champs) | 300s |
| `/tmp/claude-sl-usage-backoff` | Backoff 429 — empeche les appels API pendant 10 min | 600s |
| `/tmp/claude-sl-usage.lock` | Flock — un seul appel API a la fois (multi-instances) | — |
| `/tmp/claude-sl-git-*` | Cache git status (par repertoire) | 5s |
| `/tmp/claude-sl-status-cache` | Cache status Claude (status.claude.com) | 60s |

## Resilience API

L'API `/api/oauth/usage` est sujette a du rate limiting (429). Le script combine plusieurs mecanismes de protection :

- **Backoff 429** : apres un 429, attend 10 min avant de reessayer (`/tmp/claude-sl-usage-backoff`)
- **Flock** : un seul process appelle l'API a la fois (non-bloquant, les autres utilisent le cache)
- **Fallback 3 niveaux** pour ne jamais perdre les donnees :
  1. **API OK (200)** — met a jour le cache `/tmp` + le fichier durable `~/.claude/usage-session`
  2. **API echouee + cache existant** — recalcule les couts depuis les JSONL, preserve les quotas du cache
  3. **Cache vide** — lit le fichier durable (survit aux reboots et purges /tmp)

Le header `User-Agent: claude-code/<version>` est obligatoire pour l'API.

## Fonctionnement

Claude Code pipe un objet JSON via stdin a chaque render. Le script le parse avec `jq` pour extraire les infos du modele, du contexte, de la session et du git.

Les donnees couteuses (git status, API usage) sont cachees dans `/tmp/` pour eviter les ralentissements. Les couts (5h et hebdo) sont recalcules a chaque refresh du cache usage (300s) en scannant les fichiers JSONL du repertoire `~/.claude/projects/` (batch `find -exec +` pour performance).

## Licence

MIT
