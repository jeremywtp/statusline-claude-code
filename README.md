# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, quotas 5h/7j (+ quota Fable 7j dedie) avec calcul de cout reel depuis les logs JSONL.

## Preview

```
Opus 5 ▌▌▌▌▌ │ my-project │ v2.1.75 ●
██████░░░░░░░░░ 40% │ $1.24 │ 3m 22s │ * main +2 ~1 ?3 ↑3 ↓1
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▱▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50 │ Fable 14%
```

## Fonctionnalites

**Ligne 1 — Identite & Statut**
- Nom du modele avec couleur (Fable 5 = or/ambre, Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **⚡** (jaune) si le fast mode est actif
- Indicateur **effort level** en barres verticales (lu en direct depuis le champ `.effort.level` du JSON stdin, fallback `<local-command-stdout>` du JSONL), adapte au modele. Toutes les graduations sont des `▌` : celles atteintes prennent la couleur du niveau, les suivantes restent grises (`DIM`)
  - **Sonnet 4.6 & autres** (4 graduations) : low (1, cyan) → medium (2, jaune) → high (3, rouge) → max (4, magenta). `xhigh` retombe sur high ; **ultracode** affiche 4 graduations + `✦`
  - **Fable 5, Opus & Sonnet 5** (5 graduations) : insere xhigh (4, orange) entre high et max (xhigh existe a partir d'Opus 4.7, sur Fable 5 et sur Sonnet 5) ; le mode **ultracode** s'affiche `▌▌▌▌▌ ✦` en magenta vif
  - **Haiku** : pas d'indicateur (le modele n'a pas de niveau d'effort)
  - Niveau absent, `default` ou inconnu → rendu comme `medium`
- Nom du sub-agent (si applicable)
- Mode vim (`[N]`/`[I]`)
- Nom du projet courant
- Version de Claude Code
- Indicateur **status Claude** via [status.claude.com](https://status.claude.com) (API `summary.json`, cache 60s) :
  - `●` vert — Operational
  - `●` jaune — Degraded Performance
  - `●` orange — Partial Outage
  - `●` rouge — Major Outage
  - `●` bleu — Maintenance

**Ligne 2 — Contexte, Session & Git**
- Barre de progression du contexte avec seuils de couleur (vert < 70%, jaune < 90%, rouge >= 90%)
- Cout de la session courante (USD)
- Duree de la session
- Branche git avec fichiers staged (`+`), modifies (`~`), untracked (`?`), commits non pousses (`↑` cyan) et commits remote non recuperes (`↓` jaune)
- **Auto-fetch en background** : si l'upstream est tracke et que le dernier fetch date de plus de 5 min, lance `git fetch --quiet --no-tags` en detache (`& disown` — le statusline tourne sous bash, contrairement au hook `UserPromptSubmit` decrit plus bas qui doit rester POSIX) pour que `↓N` reste a jour sans bloquer le rendu (lock par repo dans `/tmp/claude-sl-<uid>-fetch-<cksum>`)

**Ligne 3 — Quotas d'utilisation**
- Quota 5 heures : mini-barre + pourcentage + timer avant reset + **cout 5h**
- Quota 7 jours : mini-barre + pourcentage + timer avant reset + **cout hebdo reel**
- **Quota Fable 7j** : pourcentage seul, label or/ambre — Fable 5 a sa propre limite hebdo, exposee par l'API dans `limits[]` (premiere entree `weekly_scoped` dont `scope.model.display_name` **contient** `fable` — test regex insensible a la casse, pas une egalite stricte). Le segment est masque si le compte n'a pas de limite dediee
- Donnees recuperees via l'API OAuth Anthropic (cache 300s, backoff 429 10min, verrou mkdir multi-instances)

## Calcul des couts

Les couts (5h et hebdo) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic. Le scan est limite aux fichiers modifies dans les 7 derniers jours (`find -mtime -7`) et ne retient que les messages `type == "assistant"` posterieurs au debut de la fenetre hebdo.

Les messages sont **dedupliques par `requestId`** (`group_by(.reqId) | map(last)`) : le streaming ecrit plusieurs lignes JSONL pour une meme requete, seule la derniere porte les compteurs de tokens definitifs.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API.

### Prix (USD / MTok) — Juillet 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Fable 5** (flagship) | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 5** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 5 / Opus 4.8 Fast** (`speed: fast`) | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 4.5 / 4.6 / 4.7 / 4.8** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.5 / 4.6 / 4.7 Fast** (`speed: fast`) | $30 | $150 | $37.50 | $60 | $3 |
| **Sonnet 5** (promo → 31/08/26) | $2 | $10 | $2.50 | $4 | $0.20 |
| **Sonnet 5** (standard 01/09/26 →) | $3 | $15 | $3.75 | $6 | $0.30 |
| **Sonnet 4.6** | $3 | $15 | $3.75 | $6 | $0.30 |
| **Haiku 4.5** | $1 | $5 | $1.25 | $2 | $0.10 |
| Opus legacy (4 / 4.1) | $15 | $75 | $18.75 | $30 | $1.50 |

> **Fable 5** — et **Mythos 5** (Project Glasswing, meme tier et meme tarif) — est au-dessus d'Opus (le modele le plus puissant) : $10/$50, sans fast mode.
> Fast mode : Opus 5 et Opus 4.8 ($10/$50, tarif reduit). Opus 4.7 fast ($30/$150) est retire (erreur API desormais, tarif conserve pour les messages historiques) ; Opus 4.6 fast a ete retire le 29/06/2026 (facture au tarif standard depuis) ; le calcul suit le champ `speed` reel de chaque message.
> **Sonnet 5** est en tarif promo ($2/$10) jusqu'au 31/08/2026, puis $3/$15 — la bascule est automatique selon la date de chaque message (`.ts`), sans fast mode.

#### Matching des modeles

Le tarif est choisi par test successif sur la chaine `.message.model` du JSONL, **premier match gagnant** :

`fable|mythos` → `opus-5|opus-4-8` → `opus-4-[567]` → `opus` → `haiku` → `sonnet-5` → fallback general.

Deux consequences a garder en tete :

- Le fallback general (modele non reconnu) applique le tarif **Sonnet 4.6** ($3/$15).
- Le fallback `opus` applique le tarif **legacy** ($15/$75). Un futur `opus-4-9` non ajoute au script y tomberait et serait donc facture $15/$75 au lieu de $5/$25 — l'echelle d'effort est future-proof (elle matche `*Opus*`), la table de prix ne l'est pas.

### Session semaine alignee sur Anthropic

Le script persiste le debut de la fenetre hebdomadaire dans `~/.claude/week-session` pour eviter les derives du `resets_at` (API rolling). La fenetre est recalculee dans trois cas :

1. la session a reellement expire (`now >= resets_at` stocke) ;
2. l'API renvoie un `resets_at` different de celui stocke (reset server-side anticipe par Anthropic) ;
3. premier run — aucun `resets_at` stocke, ou valeur illisible.

Hors de ces cas, le `WEEK_START` persiste tel quel, meme si l'API fait glisser son `resets_at`.

### Fast mode

Le fast mode (x6 sur Opus 4.6/4.7, x2 sur Opus 5 et Opus 4.8) est detecte de deux manieres :
- **Affichage ⚡** : lit `fastMode` dans `~/.claude/settings.json` (session courante)
- **Calcul cout** : lit le champ `speed` de chaque requete dans les JSONL (historique precis)

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

Dependances attendues : `jq`, `curl`, `git`, `bash 4+`. L'installer controle `jq`, `curl` et `git` : il refuse de continuer si l'un manque, et propose la commande apt/pacman/dnf adaptee. `bash 4+` n'est **pas** verifie a l'install (il est presume present sur Linux/WSL2) ; seule la commande `doctor` le remonte, a titre de diagnostic.

```bash
npx github:jeremywtp/statusline-claude-code
```

### macOS (Intel + Apple Silicon)

Le script d'origine utilise des commandes GNU incompatibles BSD (`stat -c`, `date -d`, `grep -oP`, `find -mmin`, et depend de Bash 5+). L'installer macOS :

1. verifie Homebrew (refuse si absent et renvoie la commande d'install Homebrew)
2. detecte Apple Silicon (`/opt/homebrew`) ou Intel (`/usr/local`)
3. `brew install coreutils findutils grep bash jq curl git` pour ce qui manque seulement
4. insere un **shim de compatibilite** dans `statusline.sh` qui redirige `stat`/`date`/`grep`/`find` vers leurs equivalents GNU (`gstat`, `gdate`, `ggrep`, `gfind`). Le shim couvre aussi `md5sum` → `gmd5sum` par precaution, mais le script ne l'appelle plus : le hachage des chemins passe par `cksum` (POSIX, natif BSD). Le verrou API utilise `mkdir` (atomique, natif partout), aucune dependance a `flock`
5. reecrit le shebang vers Bash 5+ Homebrew (macOS livre `/bin/bash` en 3.2)

Une fois installe, c'est **`statusline.sh` lui-meme** (pas l'installer) qui lit le token OAuth dans le **Keychain** (`security find-generic-password -s "Claude Code-credentials"`), en fallback de `~/.claude/.credentials.json` : Claude Code stocke le token dans le Keychain par defaut sur Mac, alors que sur Linux/WSL il l'ecrit dans le fichier. La commande `doctor` verifie la presence de l'un ou de l'autre.

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
#   --no-backup        n'ecrit pas de .bak des fichiers modifies
#   --with-fetch-hook  ajoute le hook UserPromptSubmit "git fetch" sans demander
#   --no-fetch-hook    n'ajoute pas le hook (skip prompt en mode interactif)
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

### Hook `UserPromptSubmit` (optionnel — pour `↓N` plus reactif)

Le statusline lance deja un `git fetch` en background si > 5 min depuis le dernier. Pour rendre `↓N` (commits remote non recuperes) **encore plus reactif**, l'installer propose un hook qui declenche un fetch detache a chaque message envoye.

**A l'install, le hook est propose via prompt interactif** :

```
> Hook UserPromptSubmit "git fetch" (optionnel)
  Lance "git fetch --quiet --no-tags" detache (background POSIX) a chaque message
  envoye, pour rendre ↓N (commits remote non recuperes) plus reactif.
  Sans le hook, l'auto-fetch tourne quand meme toutes les 5 min.

  Ajouter le hook UserPromptSubmit ? [y/N]
```

Pour les installs scriptees / CI (sans TTY), utiliser un flag explicite :

```bash
npx github:jeremywtp/statusline-claude-code --with-fetch-hook   # ajoute sans demander
npx github:jeremywtp/statusline-claude-code --no-fetch-hook     # skip propre
```

L'ajout est **idempotent** : relancer l'installer detecte le hook existant et ne le duplique pas. La detection est aussi compatible avec les anciennes installs sans marqueur (heuristique de signature). Si une ancienne version `& disown` est detectee, l'installer la **migre automatiquement** vers la version POSIX courante.

Si tu preferes ajouter le hook a la main, le snippet a merger dans `~/.claude/settings.json` :

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "(cd \"$CLAUDE_PROJECT_DIR\" && git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && git fetch --quiet --no-tags 2>/dev/null) </dev/null >/dev/null 2>&1 & # scc-fetch-hook"
          }
        ]
      }
    ]
  }
}
```

La double verification (`rev-parse --git-dir` + `rev-parse --abbrev-ref @{u}`) evite :
- d'erreurer dans les dossiers non-git
- de prompter SSH/HTTPS inutilement sur les branches sans upstream tracke

La redirection des trois FDs (`</dev/null >/dev/null 2>&1`) suivie de `&` detache le fetch du processus parent : il **ne bloque jamais** l'envoi du message. POSIX volontairement (pas `disown`) car Claude Code execute les hooks via `/bin/sh` — sur Debian/Ubuntu/WSL2, `/bin/sh` est `dash`, qui n'a pas le builtin bash `disown`.

Le commentaire shell `# scc-fetch-hook` est un marqueur inerte qui sert a `npx ... uninstall` pour retirer **uniquement** ce hook sans toucher aux autres `UserPromptSubmit` que tu pourrais avoir ajoutes manuellement.

## Fichiers et cache

Tous les fichiers `/tmp` sont prefixes par l'UID de l'utilisateur (`/tmp/claude-sl-$(id -u)-...`, multi-user safe) — note `<uid>` ci-dessous. Les caches par repertoire sont suffixes par le `cksum` du chemin du projet.

| Fichier | Description | TTL |
|---|---|---|
| `~/.claude/statusline.sh` | Script principal | — |
| `~/.claude/settings.json` | Config Claude Code (statusLine) | — |
| `~/.claude/week-session` | Persistance fenetre hebdo (`resets_at\|WEEK_START`) | Jusqu'au reset |
| `~/.claude/usage-session` | Persistance durable API usage (5 champs : %, timers, quota Fable) — fallback si cache /tmp vide | Jusqu'au prochain succes API |
| `/tmp/claude-sl-<uid>-usage-cache` | Cache API OAuth (quotas 5h/7j/Fable + couts, 7 champs) | 300s |
| `/tmp/claude-sl-<uid>-usage-backoff` | Backoff 429 — empeche les appels API pendant 10 min | 600s |
| `/tmp/claude-sl-<uid>-usage.lock.d` | Verrou mkdir — un seul appel API a la fois (multi-instances, casse si orphelin > 30s) | — |
| `/tmp/claude-sl-<uid>-git-<cksum>` | Cache git status par repertoire (incl. `↑N ↓N` ahead/behind) | 5s |
| `/tmp/claude-sl-<uid>-fetch-<cksum>` | Lock auto-fetch par repertoire — empeche les fetch trop frequents | 300s |
| `/tmp/claude-sl-<uid>-status-cache` | Cache status Claude (status.claude.com) | 60s |
| `/tmp/claude-sl-<uid>-week-raw-XXXXXX` | `mktemp` par process — lignes JSONL brutes de la fenetre hebdo. Supprime en fin de calcul ; les orphelins de plus de 5 min sont purges au run suivant | Ephemere |
| `/tmp/claude-sl-<uid>-api-XXXXXX` | `mktemp` par process — corps de la reponse API OAuth, supprime apres lecture | Ephemere |

## Resilience API

L'API `/api/oauth/usage` est sujette a du rate limiting (429). Le script combine plusieurs mecanismes de protection :

- **Backoff 429** : apres un 429, attend 10 min avant de reessayer (`/tmp/claude-sl-usage-backoff`)
- **Verrou mkdir** : un seul process appelle l'API a la fois (`mkdir` atomique, portable macOS/Linux — un verrou orphelin est casse apres 30s). Les autres instances utilisent le cache
- **Fallback 3 niveaux** pour ne jamais perdre les donnees :
  1. **API OK (200)** — met a jour le cache `/tmp` + le fichier durable `~/.claude/usage-session`
  2. **API echouee + cache existant** — recalcule les couts depuis les JSONL, preserve les quotas du cache
  3. **Cache vide** — lit le fichier durable (survit aux reboots et purges /tmp)

Le header `User-Agent: claude-code/<version>` est obligatoire pour l'API.

## Fonctionnement

Claude Code pipe un objet JSON via stdin a chaque render. Le script le parse en **un seul appel `jq`** pour en extraire le modele, le contexte, la session (cout, duree), le repertoire, la version, l'agent, le mode vim, le chemin du transcript et l'effort level.

Le git n'est **pas** dans ce JSON : la branche et les compteurs (staged / modifies / untracked, ahead / behind) sont obtenus en lancant de vraies commandes `git` dans le repertoire transmis par le JSON (`workspace.current_dir`).

Les donnees couteuses (git status, API usage) sont cachees dans `/tmp/` pour eviter les ralentissements. Les couts (5h et hebdo) sont recalcules a chaque refresh du cache usage (300s) en scannant les fichiers JSONL du repertoire `~/.claude/projects/` (batch `find -exec +` pour performance).

## Compatibilite

- **Locale** — le script force `LC_NUMERIC=C` au demarrage pour que `printf '%.Nf'` accepte les valeurs avec `.` (sans ca, en `fr_FR.UTF-8` qui attend `,`, tous les pourcentages et couts retombent a 0)
- **Token OAuth** — sur macOS, lu dans le Keychain `Claude Code-credentials` ; sur Linux/WSL, lu dans `~/.claude/.credentials.json`. La lecture essaie le fichier en priorite et tombe sur le Keychain si vide ET `uname = Darwin`
- **Couleurs** — toutes les couleurs sont en palette 256 (codes `\033[38;5;N` avec N >= 16) pour garantir un rendu identique sur tous les terminaux. Les codes 16-couleurs (30-37 / 90-97) sont remappes par certains terminaux (cmux, Solarized, etc.) ce qui faisait ressortir le vert en jaune et le violet en violet pale

### Effort level — sources et priorite

Claude Code applique l'effort level dans cet ordre (le premier qui matche gagne) :

1. **`CLAUDE_CODE_EFFORT_LEVEL` env var** — override absolu. Quand elle est posee, `/effort <X>` UI est bloquee : Claude Code repond `CLAUDE_CODE_EFFORT_LEVEL=<X> overrides this session — clear it and <Y> takes over`.
2. **`/effort <X>` UI dans la session courante** — override session-only.
3. **`effortLevel` dans `~/.claude/settings.json`** — baseline persistante.
4. **Defaut modele** — `xhigh` sur Opus 4.7, `high` sur Opus 4.8, `medium` ailleurs.

La statusline lit en priorite le champ **`.effort.level` du JSON stdin** transmis par Claude Code : c'est la valeur live deja resolue (elle reflete `/effort` en cours de session, l'env var, `settings.json` et le defaut modele). Cas particulier **ultracode** : Claude Code le mappe en interne sur `xhigh`, donc `.effort.level` renvoie `xhigh` (indistinct d'un vrai xhigh) ; pour l'afficher distinctement (`▌▌▌▌▌ ✦`), la statusline ne leve l'ambiguite que dans ce cas, en lisant le dernier `Set effort level to ultracode` du transcript.

Si `.effort.level` est absent (Claude Code trop ancien, ou modele sans effort comme Haiku), elle retombe sur le fallback historique. Sa preseance est **`CLAUDE_CODE_EFFORT_LEVEL` > `/effort` dans le transcript > `effortLevel` de `settings.json`** : le script lit les trois sources dans l'ordre inverse, chacune ecrasant la precedente, donc c'est bien la derniere lue (l'env var) qui gagne. Cet ordre reproduit celui de Claude Code decrit ci-dessus.

Le transcript est interroge avec deux patterns : d'abord `Set effort level to <X>` (ecrit lors d'un `/effort`), puis en repli `(current )?effort level: <X>` (lookahead 50 chars) qui couvre l'affichage de `/effort` sans argument.

**Detail technique du pattern grep `/effort`** : Claude Code ecrit deux formats distincts dans `local-command-stdout` selon que le niveau est persistant ou session-only :

- `low` / `medium` / `high` / `xhigh` (persistants) → `Set effort level to <X>: <description>`
- `max` (session-only) → `Set effort level to max (this session only): <description>`

Le pattern doit donc tolerer un suffixe variable :

```
local-command-stdout>Set effort level to \K\w+(?=[^<>]{0,200}</local-command-stdout>)
```

Le lookahead 200 chars couvre toutes les descriptions (jusqu'a ~95 chars pour `high`) tout en restant anti-faux-positif (le code source du statusline lu via Read et stocke dans le JSONL n'a pas `</local-command-stdout>` a proximite immediate).

## Licence

MIT
