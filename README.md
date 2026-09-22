# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, quotas 5h/7j (+ quota Fable 7j dedie) avec calcul de cout reel depuis les logs JSONL.

## Preview

```
Opus 5.5 ▌▌▌▌▌ │ my-project │ v2.1.280 ●
██████░░░░░░░░░ 40% │ $1.24 │ 3m 22s │ * main +2 ~1 ?3 ↑3 ↓1
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▱▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50 │ Fable 14%
```

## Fonctionnalites

**Ligne 1 — Identite & Statut**
- Nom du modele avec couleur (Fable / Mythos 5 et 5.1 = or/ambre, Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **⚡** (jaune) si le fast mode est actif (champ `.fast_mode` du JSON stdin, repli `fastMode` de `settings.json`)
- Indicateur **effort level** en barres verticales (lu en direct depuis le champ `.effort.level` du JSON stdin, fallback `<local-command-stdout>` du JSONL), adapte au modele. Toutes les graduations sont des `▌` : celles atteintes prennent la couleur du niveau, les suivantes restent grises (`DIM`)
  - **Sonnet 4.6 & autres** (4 graduations) : low (1, cyan) → medium (2, jaune) → high (3, rouge) → max (4, magenta). `xhigh` retombe sur high ; **ultracode** affiche 4 graduations + `✦`
  - **Fable / Mythos (5 et 5.1), Opus & Sonnet 5** (5 graduations) : insere xhigh (4, orange) entre high et max (xhigh existe a partir d'Opus 4.7, sur Fable / Mythos et sur Sonnet 5) ; le mode **ultracode** s'affiche `▌▌▌▌▌ ✦` en magenta vif
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
- **Quota Fable 7j** : pourcentage seul, label or/ambre — Fable (5 et 5.1) a sa propre limite hebdo, exposee par l'API dans `limits[]` (premiere entree `weekly_scoped` dont `scope.model.display_name` **contient** `fable` — test regex insensible a la casse, pas une egalite stricte, donc valable pour Fable 5.1). Le segment est masque si le compte n'a pas de limite dediee
- Donnees recuperees via l'API OAuth Anthropic (cache 300s, backoff 429 10min, verrou mkdir multi-instances)

## Calcul des couts

Les couts (5h et hebdo) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic. Le scan est limite aux fichiers modifies dans les 7 derniers jours (`find -mtime -7`) et ne retient que les messages `type == "assistant"` posterieurs au debut de la fenetre hebdo.

Les messages sont **dedupliques par `requestId`** (`group_by(.reqId) | map(last)`) : le streaming ecrit plusieurs lignes JSONL pour une meme requete, seule la derniere porte les compteurs de tokens definitifs.

**Fallback cote serveur** : quand Fable (5 / 5.1), Opus 5.5 ou Opus 5 refuse une requete et qu'elle est rejouee sur un modele de repli (dans Claude Code, seules les categories `cyber` et `bio` en ont un : bio → Opus 5, cyber → Opus 4.8 ; Opus 5 n'a pas de repli bio), le JSONL porte un tableau `usage.iterations` avec une entree par tentative et son propre `model`. C'est le registre officiel de facturation : chaque tentative ayant produit de l'output est facturee **au tarif de son modele et a sa vitesse** (la partie deja streamee par le modele qui refuse a son propre tarif, la suite au tarif du modele de repli ; le `speed` d'une entree prime sur celui de la requete, un repli pouvant le surcharger) ; une tentative refusee avant le premier token n'est pas facturee. Le script deduplique d'abord par `requestId` (derniere ligne JSONL = compteurs definitifs), puis deplie une tentative facturable par entree de `iterations` au lieu de se fier au `model` de premier niveau, qui ne designe que le modele ayant servi la reponse. Un refus sec (`stop_reason: refusal` sans output, hors fallback) n'est pas facture non plus : sa liste de tentatives est vide, ce qui neutralise aussi les lignes de streaming intermediaires de la requete.

**Web search** : les recherches web cote serveur (`usage.server_tool_use.web_search_requests`) sont facturees $10 / 1 000 requetes quel que soit le modele, en plus des tokens (rattachees a la derniere tentative, celle qui a servi la reponse) ; web fetch est gratuit.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API.

### Prix (USD / MTok) — Septembre 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Fable 5.1 / Mythos 5.1** (flagship, sorti le 01/09/26) | $10 | $50 | $12.50 | $20 | **$0.25** |
| **Fable 5 / Mythos 5** | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 5.5** (sorti le 22/09/26) | $4 | $20 | $5 | $8 | **$0.20** |
| **Opus 5.5 Fast** (`speed: fast`) | $8 | $40 | $10 | $16 | **$0.40** |
| **Opus 5 / Opus 4.8** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 5 / Opus 4.8 Fast** (`speed: fast`) | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 4.5 / 4.6 / 4.7** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.6 / 4.7 Fast** (historique, retire) | $30 | $150 | $37.50 | $60 | $3 |
| **Sonnet 5** | $2 | $10 | $2.50 | $4 | $0.20 |
| **Sonnet 4.6 / 4.5** (et fallback general) | $3 | $15 | $3.75 | $6 | $0.30 |
| **Haiku 4.5** | $1 | $5 | $1.25 | $2 | $0.10 |
| Opus legacy (4 / 4.1, retires) | $15 | $75 | $18.75 | $30 | $1.50 |

Regle generale des caches : write 5 min = x1.25 du prix input, write 1h = x2, read = x0.1 — **sauf Fable 5.1 / Mythos 5.1 ou le read vaut x0.025** ($0.25 au lieu de $1) **et Opus 5.5 ou il vaut x0.05** ($0.20). En fast mode, ces multiplicateurs s'appliquent au tarif input fast. Verifie le 22/09/2026 sur [platform.claude.com/docs/en/about-claude/pricing](https://platform.claude.com/docs/en/about-claude/pricing).

> **Fable 5.1** — et **Mythos 5.1** (Project Glasswing, meme tier et meme tarif) — sorti le 01/09/2026 : memes $10/$50 et caches write que Fable 5, mais cache read 4x moins cher ($0.25). Sans fast mode. Fable 5 / Mythos 5 restent servis au tarif precedent (cache read $1).
> **Opus 5.5** — sorti le 22/09/2026, modele par defaut de Claude Code : $4/$20 (20 % sous Opus 5), caches write $5 / $8 et cache read x0.05 ($0.20, 60 % sous Opus 5). Fast mode $8/$40 (x2, Claude API uniquement). Contexte 1M au tarif standard. Opus 5 / Opus 4.8 restent servis a $5/$25.
> Fast mode : Opus 5.5 ($8/$40), Opus 5 et Opus 4.8 ($10/$50). Opus 4.7 fast ($30/$150) est retire (erreur API desormais, tarif conserve pour les messages historiques) ; Opus 4.6 fast a ete retire le 29/06/2026 (facture au tarif standard depuis, `usage.speed` vaut `standard`) ; le calcul suit le champ `speed` reel de chaque message.
> **Sonnet 5** : le tarif de lancement $2/$10 (annonce comme introductif jusqu'au 31/08/2026) est devenu le tarif definitif — Anthropic a annule la hausse a $3/$15 prevue le 01/09/2026. Sans fast mode.
> Non pris en compte (non calculables ou sans objet depuis les JSONL Claude Code) : remise Batch API (-50 %), multiplicateur data residency x1.1 (`inference_geo: us` — les logs montrent `not_available`), surcouts fixes du system prompt tool use (deja inclus dans `input_tokens`), prime +10 % des endpoints regionaux Bedrock / Vertex. Le contexte 1M est au tarif standard sur tous les modeles 4.6+ (aucun supplement au-dela de 200K).

#### Matching des modeles

Le tarif est choisi par test successif sur la chaine `.message.model` du JSONL (ou `iterations[].model` en cas de fallback), **premier match gagnant** :

`fable-5-1|mythos-5-1` → `fable|mythos` → `opus-5-5` → `opus-5|opus-4-8` → `opus-4-[567]` → `opus-4-1[-@]|opus-4[-@]2025` (legacy) → `opus` → `haiku` → `sonnet-5` → fallback general.

Quatre consequences a garder en tete :

- Le fallback general (modele non reconnu) applique le tarif **Sonnet 4.6** ($3/$15).
- `opus-5-5` **doit** rester avant `opus-5|opus-4-8` : la regex `opus-5` capture aussi `claude-opus-5-5`, qui serait alors facture au tarif Opus 5 ($5/$25, cache read $0.50 — 2,5x trop cher sur le cache read).
- Le tarif **legacy** ($15/$75) n'est applique qu'aux deux IDs retires Opus 4 et Opus 4.1 (`claude-opus-4-20250514`, `claude-opus-4-1-20250805`, et leur forme Google Cloud `claude-opus-4-1@20250805`). Tout autre Opus non liste (futur `opus-4-9`, `opus-6`...) tombe dans la branche `opus` generique, **par hypothese** au tarif $5/$25 (fast x2 : $10/$50, comme Opus 5 / 4.8), et un futur `opus-5-x` autre que 5.5 est capture par `opus-5` (tarif Opus 5, fast compris). Un nouvel Opus est donc toujours chiffre, mais son tarif reel est a revalider a chaque sortie (Opus 5.5 est moins cher, Opus 4.1 etait plus cher).
- Un futur Fable autre que 5.1 (`fable-5-2`...) tomberait dans `fable|mythos` avec le cache read de Fable 5 ($1) : a ajuster si Anthropic reconduit le taux x0.025.

### Session semaine alignee sur Anthropic

Le script persiste le debut de la fenetre hebdomadaire dans `~/.claude/week-session` pour eviter les derives du `resets_at` (API rolling). La fenetre est recalculee dans trois cas :

1. la session a reellement expire (`now >= resets_at` stocke) ;
2. l'API renvoie un `resets_at` different de celui stocke (reset server-side anticipe par Anthropic) ;
3. premier run — aucun `resets_at` stocke, ou valeur illisible.

Hors de ces cas, le `WEEK_START` persiste tel quel, meme si l'API fait glisser son `resets_at`.

### Fast mode

Le fast mode (x2 sur Opus 5.5, Opus 5 et Opus 4.8 ; historiquement x6 sur Opus 4.6/4.7, retire depuis) est detecte de deux manieres :
- **Affichage ⚡** : lit le champ `.fast_mode` du JSON stdin, etat reel de la session (faux sur un modele sans fast mode, Fable ou Sonnet par exemple, meme si `/fast` est memorise) ; repli sur `fastMode` dans `~/.claude/settings.json` si Claude Code est trop ancien pour exposer ce champ
- **Calcul cout** : lit le champ `speed` de chaque requete dans les JSONL (historique precis)

### Thinking tokens

Les thinking tokens sont inclus dans `output_tokens` sur le dernier chunk de streaming. Pas besoin de les compter separement. Le detail `usage.output_tokens_details.thinking_tokens` des JSONL recents (thinking toujours actif sur Opus 5.5 et Fable 5.1) en est un sous-ensemble (toujours <= `output_tokens`) : l'ajouter compterait deux fois le thinking.

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

> **npx en cache ou npm 10.8** : pour forcer une version precise, ajouter `#<commit>` (`npx github:jeremywtp/statusline-claude-code#<sha>`). Si npx echoue avec `GitFetcher requires an Arborist constructor to pack a tarball` (bug de npm 10.8, vu sous Ubuntu avec node 20), passer par l'archive GitHub, qui ne demande pas git : `npx https://codeload.github.com/jeremywtp/statusline-claude-code/tar.gz/main` (ou `/tar.gz/<sha>`), suivi de la commande voulue (`install`, `doctor`...).

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

Tous les fichiers `/tmp` sont prefixes par l'UID de l'utilisateur (`/tmp/claude-sl-$(id -u)-...`, multi-user safe) — note `<uid>` ci-dessous — suivi, pour un profil autre que `~/.claude`, du suffixe de profil (voir [Plusieurs comptes Claude](#plusieurs-comptes-claude-claude_config_dir)). Les caches par repertoire sont suffixes par le `cksum` du chemin du projet. Les fichiers `~/.claude/...` ci-dessous vivent dans le dossier du profil (`$CLAUDE_CONFIG_DIR` s'il est defini).

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

## Plusieurs comptes Claude (`CLAUDE_CONFIG_DIR`)

Un second compte Claude tourne dans son propre profil : `CLAUDE_CONFIG_DIR=~/.claude-compte2 claude`. La statusline le detecte et isole tout ce qui appartient au compte :

| Element | Profil par defaut (`~/.claude`) | Autre profil (`CLAUDE_CONFIG_DIR`) |
|---|---|---|
| Jeton OAuth (quotas 5h / 7j / Fable) | Trousseau `Claude Code-credentials` (macOS) ou `~/.claude/.credentials.json` (Linux) | Trousseau `Claude Code-credentials-<8 hex>` (macOS) ou `<profil>/.credentials.json` (Linux) — **jamais** de repli sur le jeton du profil par defaut |
| Caches `/tmp` (usage, backoff, verrou, git, status) | `/tmp/claude-sl-<uid>-...` | `/tmp/claude-sl-<uid>-<8 hex>-...` |
| Fichiers durables (`usage-session`, `week-session`) et `settings.json` lu en repli | `~/.claude/` | `<profil>/` |
| JSONL scannes pour les couts | `~/.claude/projects/` | `<profil>/projects/` |

`<8 hex>` = les 8 premiers caracteres du sha256 du chemin `CLAUDE_CONFIG_DIR` tel qu'il est exporte : c'est le suffixe que Claude Code donne lui-meme a l'entree Trousseau du profil.

Un seul script sert tous les profils : l'installeur ecrit `~/.claude/statusline.sh` et `~/.claude/settings.json`, et un profil qui partage sa configuration par liens symboliques (`<profil>/settings.json -> ~/.claude/settings.json`, idem `statusline.sh`) en herite sans reinstallation. L'installeur ecrit a travers ces liens sans les remplacer.

**Limite — historique partage** : si `<profil>/projects` est un lien vers `~/.claude/projects` (sessions reprises d'un compte a l'autre), les JSONL des deux comptes sont melanges et ne portent aucun identifiant de compte par message : les **couts** 5h / 7j cumulent alors la consommation des deux comptes (chacun sur la fenetre de son propre compte). Les **pourcentages** de quota, eux, restent exacts pour chaque compte (API OAuth du compte).

## Fonctionnement

Claude Code pipe un objet JSON via stdin a chaque render. Le script le parse en **un seul appel `jq`** pour en extraire le modele, le contexte, la session (cout, duree), le repertoire, la version, l'agent, le mode vim, le chemin du transcript, l'effort level et l'etat du fast mode.

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
3. **Niveau memorise dans `~/.claude/settings.json`** — baseline persistante. Depuis Claude Code v2.1.251, `/effort` l'enregistre par modele (`modelSettings.<id>.effortLevel`), prioritaire sur la cle `effortLevel` de premier niveau. Cette ancienne cle ne s'applique plus a Opus 5.5 (ni aux modeles ulterieurs) dans le fichier utilisateur.
4. **Defaut modele** — `medium` sur Opus 5.5, `xhigh` sur Opus 4.7, `high` sur tous les autres modeles a effort (Opus 4.8 / 5, Fable 5 / 5.1, Sonnet 5...).

La statusline lit en priorite le champ **`.effort.level` du JSON stdin** transmis par Claude Code : c'est la valeur live deja resolue (elle reflete `/effort` en cours de session, l'env var, `settings.json` et le defaut modele). Cas particulier **ultracode** : Claude Code le mappe en interne sur `xhigh`, donc `.effort.level` renvoie `xhigh` (indistinct d'un vrai xhigh) ; pour l'afficher distinctement (`▌▌▌▌▌ ✦`), la statusline ne leve l'ambiguite que dans ce cas, en lisant le dernier `Set effort level to ultracode` du transcript.

Si `.effort.level` est absent (Claude Code trop ancien, ou modele sans effort comme Haiku), elle retombe sur le fallback historique. Sa preseance est **`CLAUDE_CODE_EFFORT_LEVEL` > `/effort` dans le transcript > `effortLevel` de `settings.json`** : le script lit les trois sources dans l'ordre inverse, chacune ecrasant la precedente, donc c'est bien la derniere lue (l'env var) qui gagne. Cet ordre approxime celui de Claude Code decrit ci-dessus, sans le niveau par modele (`modelSettings`, inutile ici : toute version de Claude Code qui l'ecrit fournit deja `.effort.level`) ni le defaut exact du modele (`default` s'affiche comme `medium`).

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
