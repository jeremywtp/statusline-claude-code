# Mission : Installer la statusline custom Claude Code sur macOS

## Contexte

Je veux installer la statusline custom de @jeremywtp depuis :
https://github.com/jeremywtp/statusline-claude-code

Ce script a été développé sous Linux (WSL2/Ubuntu). Il utilise des commandes GNU
qui sont **incompatibles** avec macOS nativement. Tu dois patcher le script pour
que TOUT fonctionne : affichage, coûts en $, usage API (quotas 5h/7j), timers.

## Les 6 incompatibilités GNU vs BSD macOS

| # | Commande Linux (GNU) | Lignes dans le script | Problème sur macOS (BSD) | Conséquence si non corrigé |
|---|---|---|---|---|
| 1 | `stat -c %Y` | 84, 173, 367, 377 | BSD stat n'a pas le flag `-c` | Caches toujours stale, opérations excessives |
| 2 | `date -d "string"` | 478, 481, 487, 544, 547, 638, 655 | BSD date n'a pas le flag `-d` | Fenêtres 5h/7j jamais calculées → coûts $0.00, timers `--` |
| 3 | `find -printf '%s\n'` | 290, 334 | BSD find n'a pas `-printf` | Cache coût total ne se rafraîchit jamais |
| 4 | `md5sum` | 77 | Commande inexistante sur macOS | Tous les dossiers partagent le même cache git |
| 5 | `flock -n` | 410-411 | Commande inexistante sur macOS | **L'API OAuth n'est JAMAIS appelée** → usage toujours 0% |
| 6 | `#!/bin/bash` → Bash 3.2 | shebang | macOS livre Bash 3.2 (GPL v2), le script a besoin de 4+ | Syntaxe `+=` et `for(())` potentiellement cassées |

## Étape 1 — Installer les dépendances Homebrew

Vérifie que Homebrew est installé (`which brew`). Sinon, dis-moi de l'installer d'abord.

```bash
brew install coreutils findutils bash jq curl git
```

Ensuite, vérifie que **chaque commande GNU** est bien disponible :

```bash
# Ces 4 commandes DOIVENT toutes afficher "GNU" dans leur output
gstat --version 2>&1 | head -1
gdate --version 2>&1 | head -1
gfind --version 2>&1 | head -1
gmd5sum --version 2>&1 | head -1
```

Si l'une d'elles échoue → `brew reinstall coreutils findutils`.

## Étape 2 — Cloner et copier le script

```bash
git clone https://github.com/jeremywtp/statusline-claude-code.git /tmp/statusline-claude-code
cp /tmp/statusline-claude-code/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
rm -rf /tmp/statusline-claude-code
```

## Étape 3 — Patcher le script pour macOS (CRITIQUE)

Ouvre `~/.claude/statusline.sh`. Insère le bloc suivant **JUSTE APRÈS** la ligne
`set -euo pipefail` (ligne 8) et **AVANT** la ligne `INPUT=$(cat)`.

### Pourquoi ce shim est nécessaire

Le script appelle `stat -c`, `date -d`, `find -printf`, `md5sum` et `flock` partout.
Sur macOS, ces commandes n'existent pas ou ont une syntaxe BSD différente.
Le shim ci-dessous remplace transparemment chaque commande par son équivalent GNU
installé par Homebrew (préfixé `g`), sans modifier le reste du script.

### Points critiques du shim

1. **PAS de `$(brew --prefix)`** — Claude Code lance le script avec un PATH minimal,
   `brew` n'est souvent PAS dans le PATH → le shim crasherait silencieusement.
   On détecte le chemin Homebrew en testant les dossiers directement.

2. **`flock` doit retourner 0** — Sans ça, le bloc `if flock -n 9` (ligne 411)
   échoue → `_fetch_usage` n'est JAMAIS appelé → l'API OAuth n'est jamais contactée
   → les quotas 5h/7j affichent toujours 0% et $0.00.

3. **Les fonctions wrapper se propagent dans les subshells `( ... ) &`** — Le calcul
   du coût total (lignes 296-336) tourne en background. Les fonctions Bash sont
   héritées par les subshells `()`, donc les wrappers fonctionnent dedans.

### Bloc exact à insérer

```bash

# ── macOS compatibility shim ──────────────────────────────────────────
# Remplace les commandes GNU (stat, date, find, md5sum, flock) par leurs
# équivalents Homebrew (gstat, gdate, gfind, gmd5sum) sur macOS.
# IMPORTANT : ne pas utiliser $(brew --prefix) car brew n'est pas toujours
# dans le PATH quand Claude Code lance ce script.
if [[ "$(uname)" == "Darwin" ]]; then
  if [[ -x "/opt/homebrew/bin/gstat" ]]; then
    _GNU="/opt/homebrew/bin"      # Apple Silicon (M1/M2/M3/M4)
  elif [[ -x "/usr/local/bin/gstat" ]]; then
    _GNU="/usr/local/bin"         # Intel Mac
  else
    echo "ERREUR: GNU coreutils non trouvé. Lance: brew install coreutils findutils" >&2
    exit 1
  fi
  stat()   { "$_GNU/gstat"   "$@"; }
  date()   { "$_GNU/gdate"   "$@"; }
  md5sum() { "$_GNU/gmd5sum" "$@"; }
  if [[ -x "$_GNU/gfind" ]]; then
    find() { "$_GNU/gfind" "$@"; }
  elif [[ -x "${_GNU%bin}libexec/gnubin/find" ]]; then
    find() { "${_GNU%bin}libexec/gnubin/find" "$@"; }
  fi
  flock() { return 0; }
  export -f stat date find md5sum flock 2>/dev/null
fi
# ── end macOS shim ────────────────────────────────────────────────────

```

### Résultat attendu dans le fichier

Après insertion, les lignes 8-30 environ doivent ressembler à :

```bash
set -euo pipefail

# ── macOS compatibility shim ────────── ...
if [[ "$(uname)" == "Darwin" ]]; then
  ...
fi
# ── end macOS shim ──────────────────── ...

# --- Lecture du JSON stdin (une seule fois) ---
INPUT=$(cat)
```

## Étape 4 — Configurer Claude Code

Lis le fichier `~/.claude/settings.json` s'il existe déjà.
Ajoute (ou merge) la clé `statusLine` **sans supprimer les clés existantes** :

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

## Étape 5 — S'assurer que Bash 5+ est utilisé

macOS livre `/bin/bash` en version 3.2. Homebrew installe Bash 5.x dans
`/opt/homebrew/bin/bash` (Apple Silicon) ou `/usr/local/bin/bash` (Intel).

Vérifie la version utilisée par le script :

```bash
/bin/bash --version | head -1        # probablement 3.2 (trop vieux)
/opt/homebrew/bin/bash --version | head -1  # doit être 5.x
```

Si `/bin/bash` est 3.2, change le shebang du script :

```bash
# Remplacer la première ligne de ~/.claude/statusline.sh
# DE : #!/bin/bash
# PAR : #!/opt/homebrew/bin/bash    (Apple Silicon)
# OU  : #!/usr/local/bin/bash       (Intel Mac)
```

Alternative : ajouter Homebrew au PATH dans `~/.zshrc` :

```bash
export PATH="/opt/homebrew/bin:$PATH"
```

## Étape 6 — Vérification complète

### Test 1 : Le script tourne sans erreur

```bash
echo '{"model":"claude-opus-4-6","contextWindow":{"contextTokens":80000,"maxContextTokens":200000,"used_percentage":40,"context_window_size":200000},"cost":{"totalCostUsd":1.25,"total_cost_usd":1.25,"total_duration_ms":600000,"total_lines_added":150,"total_lines_removed":30},"session":{"linesAdded":150,"linesRemoved":30,"durationMs":600000},"version":"1.0.45","exceeds_200k_tokens":false}' | ~/.claude/statusline.sh
```

Tu dois voir **3 lignes** avec des couleurs ANSI. Vérifie que :
- Ligne 1 : nom du modèle (Opus), version, point vert status
- Ligne 2 : barre de contexte, **`$1.25`** (PAS `$0.00`), lignes +150 -30, durée
- Ligne 3 : quotas 5h et 7j avec barres ▰▱ (les valeurs peuvent être 0% au premier lancement, c'est normal — elles se remplissent après le premier appel API qui prend ~5 min de cache)

### Test 2 : Les commandes GNU fonctionnent dans le shim

```bash
bash -c '
  source <(sed -n "9,30p" ~/.claude/statusline.sh)
  echo "stat: $(stat -c %Y /tmp 2>&1 | head -1)"
  echo "date: $(date -d "2026-01-01" +%s 2>&1)"
  echo "md5sum: $(echo test | md5sum 2>&1 | cut -d" " -f1)"
  echo "find: $(find /tmp -maxdepth 0 -printf "%s" 2>&1)"
  echo "flock: $(flock -n 9 2>&1; echo $?)"
'
```

Chaque ligne doit afficher une **valeur** (pas "command not found" ni "illegal option").

### Test 3 : Vérifier que l'API OAuth sera appelée

```bash
cat ~/.claude/.credentials.json 2>/dev/null | jq -r '.claudeAiOauth.accessToken // "ABSENT"' | head -c 20
```

Doit afficher les premiers caractères d'un token (pas "ABSENT"). Si c'est "ABSENT",
il faut se connecter à Claude Code au moins une fois pour générer les credentials.

## Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| Le script ne s'affiche pas du tout | `statusLine` absent du settings.json | Vérifier `~/.claude/settings.json` |
| Erreur "gstat: command not found" | coreutils pas installé | `brew install coreutils` |
| Erreur "gfind: command not found" | findutils pas installé | `brew install findutils` |
| Coûts affichent `$0.00` partout | `date -d` échoue → fenêtres temporelles vides | Vérifier que le shim est bien inséré et que `gdate` fonctionne |
| Usage 5h/7j affiche `0%` et `--` | `flock` échoue → API jamais appelée | Vérifier que `flock() { return 0; }` est dans le shim |
| Bash syntax error near `+=` | Bash 3.2 utilisé au lieu de 5.x | Changer le shebang ou ajouter brew au PATH |
| Mac Intel : shim dit "non trouvé" | Homebrew est dans `/usr/local/` pas `/opt/homebrew/` | Le shim détecte les deux, mais vérifier que gstat existe dans `/usr/local/bin/` |

## Résumé

À la fin, donne-moi :
1. La version de Bash utilisée par le script
2. Le résultat du test 1 (les 3 lignes)
3. Le résultat du test 2 (les 5 commandes GNU)
4. Le contenu du shim tel qu'inséré dans le fichier
5. Si tout est OK ou s'il reste des problèmes
