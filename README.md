# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, quotas 5h/7j avec calcul de cout reel depuis les logs JSONL.

## Preview

```
Claude Opus 4.6 1M ⚡ ▌▌░ │ my-project │ * main +2 ~1 ?3 │ v2.1.69 ●
██████░░░░░░░░░ 40% │ $1.24 │ +45 -12 │ 3m 22s
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▰▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50
```

## Fonctionnalites

**Ligne 1 — Identite & Git**
- Nom du modele avec couleur (Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **1M** (jaune) si le contexte est > 200K tokens
- Indicateur **⚡** (jaune) si le fast mode est actif (`fastMode` dans `settings.json`)
- Indicateur **effort level** en barres verticales : `▌░░` low (cyan), `▌▌░` medium/default (jaune), `▌▌▌` high (rouge)
- Nom du sub-agent (si applicable)
- Mode vim (`[N]`/`[I]`)
- Nom du projet courant
- Branche git avec fichiers staged (`+`), modifies (`~`), et untracked (`?`)
- Version de Claude Code
- Indicateur **status Claude** : `●` vert (OK), orange (degrade), rouge (incident) — via [status.claude.com](https://status.claude.com)

**Ligne 2 — Contexte & Session**
- Barre de progression du contexte avec seuils de couleur (vert < 70%, jaune < 90%, rouge >= 90%)
- Alerte `!` rouge si > 200K tokens
- Cout de la session courante (USD)
- Lignes ajoutees/supprimees
- Duree de la session

**Ligne 3 — Quotas d'utilisation**
- Quota 5 heures : mini-barre + pourcentage + timer avant reset + **cout 5h**
- Quota 7 jours : mini-barre + pourcentage + timer avant reset + **cout hebdo reel**
- Donnees recuperees via l'API OAuth Anthropic (cache 120s, persistance durable)

## Calcul des couts

Les couts (5h et hebdo) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API.

### Prix (USD / MTok) — Mars 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Opus 4.6** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.6 Fast** | $30 | $150 | $37.50 | $60 | $3 |
| **Opus 4.6 Long (>200K)** | $10 | $37.50 | $12.50 | $20 | $1 |
| **Opus 4.6 Fast + Long** | $60 | $225 | $75 | $120 | $6 |
| **Sonnet 4.6** | $3 | $15 | $3.75 | $6 | $0.30 |
| **Sonnet Long (>200K)** | $6 | $22.50 | $7.50 | $12 | $0.60 |
| **Haiku 4.5** | $1 | $5 | $1.25 | $2 | $0.10 |
| Opus legacy | $15 | $75 | $18.75 | $30 | $1.50 |

### Session semaine alignee sur Anthropic

Le script persiste le debut de la fenetre hebdomadaire dans `~/.claude/week-session` pour eviter les derives du `resets_at` (API rolling). La fenetre ne se recalcule que lorsque la session expire reellement (`now >= resets_at`).

### Fast mode

Le fast mode (x6 sur tous les prix) est detecte de deux manieres :
- **Affichage ⚡** : lit `fastMode` dans `~/.claude/settings.json` (session courante)
- **Calcul cout** : lit le champ `speed` de chaque requete dans les JSONL (historique precis)

### Thinking tokens

Les thinking tokens sont inclus dans `output_tokens` sur le dernier chunk de streaming. Pas besoin de les compter separement.

## Dependances

- `jq` — parsing JSON
- `curl` — appels API pour les quotas
- `git` — branche et status

```bash
# Ubuntu/Debian
sudo apt install -y jq curl git
```

## Installation

1. Copier le script :

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Ajouter dans `~/.claude/settings.json` :

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

3. Redemarrer Claude Code.

## Fichiers et cache

| Fichier | Description | TTL |
|---|---|---|
| `~/.claude/statusline.sh` | Script principal | — |
| `~/.claude/settings.json` | Config Claude Code (fastMode, effortLevel, statusLine) | — |
| `~/.claude/week-session` | Persistance fenetre hebdo (`resets_at\|WEEK_START`) | Jusqu'au reset |
| `~/.claude/usage-session` | Persistance durable API usage (%, timers) — fallback si cache /tmp vide | Jusqu'au prochain succes API |
| `/tmp/claude-sl-usage-cache` | Cache API OAuth (quotas + couts 5h/7j) | 120s |
| `/tmp/claude-sl-git-*` | Cache git status (par repertoire) | 5s |
| `/tmp/claude-sl-status-cache` | Cache status Claude (status.claude.com) | 60s |

## Resilience API

L'API `/api/oauth/usage` est sujette a du rate limiting (429). Le script utilise une chaine de fallback a 3 niveaux pour ne jamais perdre les donnees :

1. **API OK (200)** — met a jour le cache `/tmp` + le fichier durable `~/.claude/usage-session`
2. **API 429 + cache existant** — garde les anciennes valeurs du cache
3. **API 429 + cache vide** — lit le fichier durable (survit aux reboots et purges /tmp)

Le header `User-Agent: claude-code/<version>` est obligatoire pour l'API.

## Fonctionnement

Claude Code pipe un objet JSON via stdin a chaque render. Le script le parse avec `jq` pour extraire les infos du modele, du contexte, de la session et du git.

Les donnees couteuses (git status, API usage) sont cachees dans `/tmp/` pour eviter les ralentissements. Les couts (5h et hebdo) sont recalcules a chaque refresh du cache usage (120s) en scannant tous les fichiers JSONL du repertoire `~/.claude/projects/`.

## Licence

MIT
