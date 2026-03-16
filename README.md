# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, cout total lifetime, quotas 5h/7j avec calcul de cout reel depuis les logs JSONL.

## Preview

```
Opus 4.6 (1M context) ⚡ ▌▌▌▌ │ my-project │ * main +2 ~1 ?3 │ v2.1.75 ●
██████░░░░░░░░░ 40% │ $1.24 │ +45 -12 │ 3m 22s │ Σ $1501
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▰▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50
```

## Fonctionnalites

**Ligne 1 — Identite & Git**
- Nom du modele avec couleur (Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **⚡** (jaune) si le fast mode est actif
- Indicateur **effort level** en barres verticales (detection live via `<local-command-stdout>` dans le JSONL de session) :
  - `▌░░░` low (cyan)
  - `▌▌░░` medium/default (jaune)
  - `▌▌▌░` high (rouge)
  - `▌▌▌▌` max (magenta, Opus 4.6 uniquement)
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
- **Cout total lifetime** `(Σ$X,XXX)` — cumul de toutes les sessions depuis le premier lancement (calcul background, cache durable)
- Lignes ajoutees/supprimees
- Duree de la session

**Ligne 3 — Quotas d'utilisation**
- Quota 5 heures : mini-barre + pourcentage + timer avant reset + **cout 5h**
- Quota 7 jours : mini-barre + pourcentage + timer avant reset + **cout hebdo reel**
- Donnees recuperees via l'API OAuth Anthropic (cache 300s, backoff 429 10min, flock multi-instances)

## Calcul des couts

Les couts (5h, hebdo et lifetime) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API.

### Cout total lifetime

Le cout total cumule toutes les sessions depuis le premier lancement de Claude Code. Le calcul est lance en **background** pour ne jamais bloquer l'affichage. Le resultat est cache dans `~/.claude/total-cost-cache` et recalcule automatiquement quand la taille des fichiers JSONL change (TTL minimum 300s). Utilise `grep` comme pre-filtre rapide suivi de `jq` pour la deduplication et le pricing par modele (Opus 4.5/4.6, Opus legacy, Sonnet, Haiku).

### Prix (USD / MTok) — Mars 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Opus 4.6** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.6 Fast** | $30 | $150 | $37.50 | $60 | $3 |
| **Sonnet 4.6** | $3 | $15 | $3.75 | $6 | $0.30 |
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
| `~/.claude/settings.json` | Config Claude Code (statusLine) | — |
| `~/.claude/week-session` | Persistance fenetre hebdo (`resets_at\|WEEK_START`) | Jusqu'au reset |
| `~/.claude/usage-session` | Persistance durable API usage (%, timers) — fallback si cache /tmp vide | Jusqu'au prochain succes API |
| `~/.claude/total-cost-cache` | Cout total lifetime (`COST\|BYTES\|EPOCH`) — calcul background ~3s | 300s + detection changement |
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
