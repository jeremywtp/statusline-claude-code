#!/bin/bash
# ============================================================================
# Claude Code Statusline — Be Hype / Digiflow Agency
# Developpeur : NeoZiboy
# Statusline 3 lignes : identite/git + metriques/contexte + usage hebdo
# Dependance : jq (sudo apt install -y jq)
# ============================================================================
set -euo pipefail

# Forcer le separateur decimal "." pour printf '%.Nf' (sinon echec en locale fr_FR
# qui attend "8,0" et fait tomber tous les pourcentages/couts a 0).
export LC_NUMERIC=C

# --- Lecture du JSON stdin (une seule fois) ---
INPUT=$(cat)

# --- Couleurs ANSI ---
# Palette 256 (codes >= 16) pour un rendu identique sur tous les terminaux.
# Les codes 16-couleurs (30-37 / 90-97) sont remappes par certains terminaux
# (cmux, Solarized, etc.) ce qui faisait ressortir le vert en jaune et le
# violet en violet pale. Les codes 256 sont fixes, pas configurables.
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

RED='\033[38;5;196m'
GREEN='\033[38;5;40m'
YELLOW='\033[38;5;220m'
BLUE='\033[38;5;33m'
MAGENTA='\033[38;5;129m'
CYAN='\033[38;5;39m'
WHITE='\033[38;5;255m'
GRAY='\033[38;5;244m'

BRED='\033[38;5;203m'
BGREEN='\033[38;5;82m'
BYELLOW='\033[38;5;227m'
BCYAN='\033[38;5;51m'
ORANGE='\033[38;5;208m'
UMAGENTA='\033[38;5;201m'  # magenta vif — reserve a ultracode (effort "ultra")
GOLD='\033[38;5;214m'      # or/ambre — reserve a Fable / Mythos (5 et 5.1, tier flagship au-dessus d'Opus)

# --- Separateur fin │ ---
SEP="${DIM}${GRAY} \xe2\x94\x82 ${RST}"

# --- Prefixe caches /tmp/ isole par UID (multi-user safe) ---
_SL_PREFIX="/tmp/claude-sl-$(id -u 2>/dev/null || echo 0)"

# --- Extraction JSON en un seul appel jq ---
# Bug fix : eval "" retourne 0, donc le fallback || ne s'execute jamais.
# On stocke la sortie jq d'abord, puis on teste si elle est non-vide.
MODEL_NAME="---"; DIR="."; VERSION="---"; COST=0; DURATION_MS=0; CTX_PCT=0
AGENT_NAME=""; VIM_MODE=""; TRANSCRIPT_PATH=""; EFFORT_STDIN=""

_JQ_OUT=$(echo "$INPUT" | jq -r '
  @sh "MODEL_NAME=\(.model.display_name // "---")",
  @sh "DIR=\(.workspace.current_dir // .cwd // ".")",
  @sh "VERSION=\(.version // "---")",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "CTX_PCT=\(.context_window.used_percentage // 0)",
  @sh "AGENT_NAME=\(.agent.name // "")",
  @sh "VIM_MODE=\(.vim.mode // "")",
  @sh "TRANSCRIPT_PATH=\(.transcript_path // "")",
  @sh "EFFORT_STDIN=\(.effort.level // "")"
' 2>/dev/null) || true

[ -n "$_JQ_OUT" ] && eval "$_JQ_OUT"

# --- Nom du projet ---
PROJECT="${DIR##*/}"

# --- Pourcentage contexte (entier) ---
CTX_PCT_INT=$(printf '%.0f' "$CTX_PCT" 2>/dev/null) || CTX_PCT_INT=0

# --- Couleur du modele ---
case "$MODEL_NAME" in
  *Fable*|*fable*|*Mythos*|*mythos*) MC="$GOLD" ;;
  *Opus*|*opus*)     MC="$MAGENTA" ;;
  *Sonnet*|*sonnet*) MC="$BLUE" ;;
  *Haiku*|*haiku*)   MC="$CYAN" ;;
  *)                 MC="$WHITE" ;;
esac

# ============================================================================
# GIT : cache par repertoire avec TTL de 5 secondes
# ============================================================================
GIT_CACHE_KEY="${_SL_PREFIX}-git-$(printf '%s' "$DIR" | cksum 2>/dev/null | cut -d' ' -f1 || echo 'default')"
GIT_CACHE_TTL=5

git_cache_stale() {
  [ ! -f "$GIT_CACHE_KEY" ] && return 0
  local now file_age
  now=$(date +%s)
  file_age=$(stat -c %Y "$GIT_CACHE_KEY" 2>/dev/null || echo 0)
  [ $((now - file_age)) -gt "$GIT_CACHE_TTL" ]
}

GIT_BRANCH=""
GIT_STAGED=0
GIT_MODIFIED=0
GIT_UNTRACKED=0
GIT_AHEAD=0
GIT_BEHIND=0
GIT_AVAILABLE=false

if git_cache_stale; then
  if git -C "$DIR" --no-optional-locks rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    GIT_STAGED=$(git -C "$DIR" --no-optional-locks diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    GIT_MODIFIED=$(git -C "$DIR" --no-optional-locks diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    GIT_UNTRACKED=$(git -C "$DIR" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    # Ahead/behind vs upstream tracke (silencieux si pas d'upstream)
    if git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref '@{u}' > /dev/null 2>&1; then
      read -r GIT_AHEAD GIT_BEHIND < <(git -C "$DIR" --no-optional-locks rev-list --left-right --count HEAD...@{u} 2>/dev/null) || true
      GIT_AHEAD=${GIT_AHEAD:-0}
      GIT_BEHIND=${GIT_BEHIND:-0}
    fi
    GIT_AVAILABLE=true
  fi
  echo "${GIT_AVAILABLE}|${GIT_BRANCH}|${GIT_STAGED}|${GIT_MODIFIED}|${GIT_UNTRACKED}|${GIT_AHEAD}|${GIT_BEHIND}" > "$GIT_CACHE_KEY" 2>/dev/null || true
else
  IFS='|' read -r GIT_AVAILABLE GIT_BRANCH GIT_STAGED GIT_MODIFIED GIT_UNTRACKED GIT_AHEAD GIT_BEHIND < "$GIT_CACHE_KEY" 2>/dev/null || true
  GIT_AHEAD=${GIT_AHEAD:-0}
  GIT_BEHIND=${GIT_BEHIND:-0}
fi

# --- Auto-fetch background ---
# Si > 5 min depuis le dernier fetch ET upstream tracke, lance "git fetch" en
# detache. Le rendu n'attend pas (& disown). Lock par repo via cksum du DIR.
FETCH_LOCK="${_SL_PREFIX}-fetch-$(printf '%s' "$DIR" | cksum 2>/dev/null | cut -d' ' -f1 || echo 'default')"
FETCH_TTL=300
fetch_stale() {
  [ ! -f "$FETCH_LOCK" ] && return 0
  local now age
  now=$(date +%s)
  age=$(stat -c %Y "$FETCH_LOCK" 2>/dev/null || echo 0)
  [ $((now - age)) -gt "$FETCH_TTL" ]
}
if [ "$GIT_AVAILABLE" = "true" ] && fetch_stale; then
  if git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref '@{u}' > /dev/null 2>&1; then
    touch "$FETCH_LOCK" 2>/dev/null || true
    ( git -C "$DIR" --no-optional-locks fetch --quiet --no-tags 2>/dev/null ) & disown 2>/dev/null || true
  fi
fi

# --- Segment git ---
GIT_SEGMENT=""
if [ "$GIT_AVAILABLE" = "true" ] && [ -n "$GIT_BRANCH" ]; then
  GIT_SEGMENT="$(printf '%b' "${SEP}${BCYAN}")* ${GIT_BRANCH}$(printf '%b' "${RST}")"

  GIT_PARTS=""
  [ "$GIT_STAGED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${BGREEN}+${GIT_STAGED}${RST}")"
  [ "$GIT_MODIFIED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${BYELLOW}~${GIT_MODIFIED}${RST}")"
  [ "$GIT_UNTRACKED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${RED}?${GIT_UNTRACKED}${RST}")"
  [ "$GIT_AHEAD" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${CYAN}↑${GIT_AHEAD}${RST}")"
  [ "$GIT_BEHIND" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${BYELLOW}↓${GIT_BEHIND}${RST}")"

  [ -n "$GIT_PARTS" ] && GIT_SEGMENT="${GIT_SEGMENT}${GIT_PARTS}"
fi

# ============================================================================
# LIGNE 1 : Modele | Fast | Effort | Agent | Vim | Projet | Version | Status
# ============================================================================
LINE1="$(printf '%b' "${BOLD}${MC}")${MODEL_NAME}$(printf '%b' "${RST}")"

# Indicateurs Fast mode + Effort level
# Fast mode : aucun champ dans le JSON stdin, lu dans settings.json.
FAST_MODE=$(jq -r '.fastMode // false' "$HOME/.claude/settings.json" 2>/dev/null) || FAST_MODE="false"

# Effort level — source canonique : .effort.level du JSON stdin. Valeur LIVE
# resolue par Claude Code (reflete /effort en cours de session, et "ultra" =
# ultracode). Absente si le modele ne supporte pas l'effort (Haiku) ou si Claude
# Code est trop ancien pour exposer ce champ → fallback historique. Les trois
# sources sont lues dans l'ordre settings.json, transcript, env var : chacune
# ecrase la precedente, donc la preseance reelle est l'inverse de l'ordre de
# lecture → env var > transcript > settings.json.
if [ -n "$EFFORT_STDIN" ]; then
  EFFORT_LEVEL="$EFFORT_STDIN"
  # ultracode est rendu "xhigh" dans le stdin (mapping interne de Claude Code) :
  # le champ .effort.level ne le distingue PAS d'un vrai xhigh. On leve l'ambiguite
  # uniquement dans ce cas, via le dernier /effort du transcript ("ultracode").
  if [ "$EFFORT_STDIN" = "xhigh" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    _LAST_EFFORT=$(grep -oP 'local-command-stdout>Set effort level to \K\w+(?=[^<>]{0,200}</local-command-stdout>)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || _LAST_EFFORT=""
    [ "$_LAST_EFFORT" = "ultracode" ] && EFFORT_LEVEL="ultracode"
  fi
else
  EFFORT_LEVEL=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null) || EFFORT_LEVEL="default"
  # Claude Code ecrit deux formats dans local-command-stdout selon que le niveau
  # est persistant ou session-only :
  #   - low/medium/high/xhigh : "Set effort level to <X>: <description>"
  #   - max                   : "Set effort level to max (this session only): ..."
  # Lookahead 200 chars : tolere le suffixe variable, anti-faux-positif.
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    _LIVE_EFFORT=$(grep -oP 'local-command-stdout>Set effort level to \K\w+(?=[^<>]{0,200}</local-command-stdout>)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || _LIVE_EFFORT=""
    [ -z "$_LIVE_EFFORT" ] && _LIVE_EFFORT=$(grep -ioP 'local-command-stdout>(?:current )?effort level: \K\w+(?=[^<>]{0,50}</local-command-stdout>)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || true
    [ -n "$_LIVE_EFFORT" ] && EFFORT_LEVEL="$_LIVE_EFFORT"
  fi
  # Env var CLAUDE_CODE_EFFORT_LEVEL : override absolu cote Claude Code.
  if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
    EFFORT_LEVEL="$CLAUDE_CODE_EFFORT_LEVEL"
  fi
fi
if [ "$FAST_MODE" = "true" ]; then
  LINE1="${LINE1} $(printf '%b' "${BYELLOW}\xe2\x9a\xa1${RST}")"
fi

# Barres verticales style signal pour l'effort level
# Haiku : aucune barre | Fable / Mythos (5 et 5.1) + Opus (toutes versions) + Sonnet 5 :
# echelle 5 niveaux (xhigh dispo des Opus 4.7, sur Fable / Mythos et sur Sonnet 5) | Sonnet 4.6 &
# autres : 4 niveaux. On matche tous les Opus plutot qu'une version precise :
# future-proof (4.8, 4.9...) et sans piege de comparaison de version (4.10 < 4.7 en
# flottant). Les Opus < 4.7 n'emettent jamais xhigh, donc la 4e graduation reste
# inutilisee pour eux. Sonnet 5 est le premier Sonnet a supporter xhigh (5 niveaux).
BAR_CHAR="\xe2\x96\x8c"  # ▌ left half block
case "$MODEL_NAME" in
  *Haiku*|*haiku*)
    : # pas d'indicateur d'effort sur Haiku
    ;;
  *Fable*|*fable*|*Mythos*|*mythos*|*Opus*|*opus*|*"Sonnet 5"*|*"sonnet 5"*)
    # 5 niveaux : low, medium, high, xhigh, max
    case "$EFFORT_LEVEL" in
      low)     LINE1="${LINE1} $(printf '%b' "${CYAN}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
      high)    LINE1="${LINE1} $(printf '%b' "${BRED}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
      xhigh)   LINE1="${LINE1} $(printf '%b' "${ORANGE}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${RST}")" ;;
      max)     LINE1="${LINE1} $(printf '%b' "${MAGENTA}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
      ultra|ultracode) LINE1="${LINE1} $(printf '%b' "${UMAGENTA}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST} ${UMAGENTA}\xe2\x9c\xa6${RST}")" ;;
      *)       LINE1="${LINE1} $(printf '%b' "${BYELLOW}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
    esac
    ;;
  *)
    # 4 niveaux : low, medium, high, max (xhigh fallback sur high)
    case "$EFFORT_LEVEL" in
      low)         LINE1="${LINE1} $(printf '%b' "${CYAN}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
      high|xhigh)  LINE1="${LINE1} $(printf '%b' "${BRED}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${RST}")" ;;
      max)         LINE1="${LINE1} $(printf '%b' "${MAGENTA}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
      ultra|ultracode) LINE1="${LINE1} $(printf '%b' "${UMAGENTA}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST} ${UMAGENTA}\xe2\x9c\xa6${RST}")" ;;
      *)           LINE1="${LINE1} $(printf '%b' "${BYELLOW}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
    esac
    ;;
esac

# Agent (si present)
[ -n "$AGENT_NAME" ] && LINE1="${LINE1} $(printf '%b' "${DIM}${GRAY}")@${AGENT_NAME}$(printf '%b' "${RST}")"

# Vim mode (si present)
if [ -n "$VIM_MODE" ]; then
  case "$VIM_MODE" in
    NORMAL) LINE1="${LINE1} $(printf '%b' "${GREEN}[N]${RST}")" ;;
    INSERT) LINE1="${LINE1} $(printf '%b' "${YELLOW}[I]${RST}")" ;;
  esac
fi

# Projet
LINE1="${LINE1}$(printf '%b' "${SEP}${WHITE}${BOLD}")${PROJECT}$(printf '%b' "${RST}")"

# Version
LINE1="${LINE1}$(printf '%b' "${SEP}${DIM}${GRAY}")v${VERSION}$(printf '%b' "${RST}")"

# Status Claude (status.claude.com — cache 60s)
STATUS_CACHE="${_SL_PREFIX}-status-cache"
STATUS_CACHE_TTL=60

_status_stale() {
  [ ! -f "$STATUS_CACHE" ] && return 0
  [ $(($(date +%s) - $(stat -c %Y "$STATUS_CACHE" 2>/dev/null || echo 0))) -gt "$STATUS_CACHE_TTL" ]
}

if _status_stale; then
  # summary.json inclut incidents, composants et maintenances programmees
  _STATUS_JSON=$(curl -sf --max-time 3 "https://status.claude.com/api/v2/summary.json" 2>/dev/null) || _STATUS_JSON=""
  if [ -n "$_STATUS_JSON" ]; then
    echo "$_STATUS_JSON" | jq -r '
      # Severite des incidents non resolus
      (
        [.incidents // [] | .[] | select(.resolved_at == null) | .impact] |
        if any(. == "critical") then 4
        elif any(. == "major") then 3
        elif any(. == "minor") then 2
        else 0 end
      ) as $inc |
      # Severite des composants (pire etat)
      (
        [.components // [] | .[] | .status] |
        if any(. == "major_outage") then 4
        elif any(. == "partial_outage") then 3
        elif any(. == "degraded_performance") then 2
        elif any(. == "under_maintenance") then -1
        else 0 end
      ) as $comp |
      # Maintenance en cours
      (
        [.scheduled_maintenances // [] | .[] | select(.status == "in_progress")] | length > 0
      ) as $maint |
      # Priorite : pire severite, puis maintenance
      if ($inc >= $comp and $inc > 0) then
        (if $inc >= 4 then "critical" elif $inc >= 3 then "major" else "minor" end)
      elif $comp > 0 then
        (if $comp >= 4 then "critical" elif $comp >= 3 then "major" else "minor" end)
      elif $comp == -1 or $maint then "maintenance"
      else "none" end
    ' > "$STATUS_CACHE" 2>/dev/null || true
  fi
fi

STATUS_IND=$(cat "$STATUS_CACHE" 2>/dev/null) || STATUS_IND="none"
DOT="\xe2\x97\x8f"  # ●
case "$STATUS_IND" in
  none)        LINE1="${LINE1} $(printf '%b' "${BGREEN}${DOT}${RST}")" ;;
  minor)       LINE1="${LINE1} $(printf '%b' "${BYELLOW}${DOT}${RST}")" ;;
  major)       LINE1="${LINE1} $(printf '%b' "${ORANGE}${DOT}${RST}")" ;;
  critical)    LINE1="${LINE1} $(printf '%b' "${BRED}${DOT}${RST}")" ;;
  maintenance) LINE1="${LINE1} $(printf '%b' "${BLUE}${DOT}${RST}")" ;;
esac

# ============================================================================
# LIGNE 2 : Barre contexte | Cout session | Duree | Git
# ============================================================================

# --- Barre de progression ---
BAR_WIDTH=15
FILLED=$((CTX_PCT_INT * BAR_WIDTH / 100))
[ "$FILLED" -gt "$BAR_WIDTH" ] && FILLED=$BAR_WIDTH
EMPTY=$((BAR_WIDTH - FILLED))

if [ "$CTX_PCT_INT" -ge 90 ]; then
  BAR_COLOR="$BRED"
  PCT_LABEL="$(printf '%b' "${BOLD}${BRED}")${CTX_PCT_INT}%$(printf '%b' "${RST}")"
elif [ "$CTX_PCT_INT" -ge 70 ]; then
  BAR_COLOR="$BYELLOW"
  PCT_LABEL="$(printf '%b' "${BOLD}${BYELLOW}")${CTX_PCT_INT}%$(printf '%b' "${RST}")"
else
  BAR_COLOR="$BGREEN"
  PCT_LABEL="$(printf '%b' "${BGREEN}")${CTX_PCT_INT}%$(printf '%b' "${RST}")"
fi

BAR_FILLED=""
BAR_EMPTY=""
for ((i=0; i<FILLED; i++)); do BAR_FILLED+="█"; done
for ((i=0; i<EMPTY; i++)); do BAR_EMPTY+="░"; done

BAR_SEGMENT="$(printf '%b' "${BAR_COLOR}")${BAR_FILLED}$(printf '%b' "${DIM}${GRAY}")${BAR_EMPTY}$(printf '%b' "${RST}") ${PCT_LABEL}"

# --- Session : cout ---
COST_FMT=$(printf '$%.2f' "$COST" 2>/dev/null) || COST_FMT='$0.00'
SESSION_SEGMENT="$(printf '%b' "${YELLOW}")${COST_FMT}$(printf '%b' "${RST}")"

# --- Duree de session ---
DURATION_MS=${DURATION_MS%.*}
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))
if [ "$MINS" -gt 0 ]; then
  DURATION_FMT="${MINS}m ${SECS}s"
else
  DURATION_FMT="${SECS}s"
fi
DURATION_SEGMENT="$(printf '%b' "${GRAY}")${DURATION_FMT}$(printf '%b' "${RST}")"

# Assemblage ligne 2
LINE2="${BAR_SEGMENT}$(printf '%b' "${SEP}")${SESSION_SEGMENT}$(printf '%b' "${SEP}")${DURATION_SEGMENT}${GIT_SEGMENT}"

# ============================================================================
# LIGNE 3 : Usage reel via API OAuth Anthropic (5h + 7j + Fable 7j)
# Source : /api/oauth/usage — donnees officielles du plan Max20
# Cache dans /tmp avec TTL de 300s + backoff 600s sur 429 + verrou mkdir multi-instances
# ============================================================================
USAGE_CACHE="${_SL_PREFIX}-usage-cache"
USAGE_CACHE_TTL=300
USAGE_BACKOFF_FILE="${_SL_PREFIX}-usage-backoff"
USAGE_BACKOFF_TTL=600
USAGE_LOCK_DIR="${_SL_PREFIX}-usage.lock.d"
USAGE_SESSION_FILE="$HOME/.claude/usage-session"

usage_cache_stale() {
  [ ! -f "$USAGE_CACHE" ] && return 0
  local now file_age
  now=$(date +%s)
  file_age=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)
  [ $((now - file_age)) -gt "$USAGE_CACHE_TTL" ]
}

# Backoff actif apres un 429 : attendre 10 min avant de reessayer
usage_in_backoff() {
  [ ! -f "$USAGE_BACKOFF_FILE" ] && return 1
  local now file_age
  now=$(date +%s)
  file_age=$(stat -c %Y "$USAGE_BACKOFF_FILE" 2>/dev/null || echo 0)
  [ $((now - file_age)) -le "$USAGE_BACKOFF_TTL" ]
}

if usage_cache_stale && ! usage_in_backoff; then
  # Recuperer le cache precedent pour fallback
  PREV_USAGE=""; PREV_WEEK_COST="0"; PREV_BLOCK_COST="0"
  if [ -f "$USAGE_CACHE" ]; then
    PREV_USAGE=$(cat "$USAGE_CACHE" 2>/dev/null) || PREV_USAGE=""
    PREV_WEEK_COST=$(echo "$PREV_USAGE" | awk -F'|' '{print $6}') || PREV_WEEK_COST="0"
    PREV_BLOCK_COST=$(echo "$PREV_USAGE" | awk -F'|' '{print $7}') || PREV_BLOCK_COST="0"
  fi

  # --- Appel API OAuth usage (verrou mkdir : un seul process a la fois) ---
  # Source du token : .credentials.json (Linux/WSL) ou Keychain (defaut macOS).
  OAUTH_TOKEN=""
  if [ -f "$HOME/.claude/.credentials.json" ]; then
    OAUTH_TOKEN=$(jq -r '.claudeAiOauth.accessToken // ""' "$HOME/.claude/.credentials.json" 2>/dev/null) || OAUTH_TOKEN=""
  fi
  if [ -z "$OAUTH_TOKEN" ] && [ "$(uname)" = "Darwin" ]; then
    # Claude Code stocke le token dans le Keychain par defaut sur macOS.
    _KC_JSON=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null) || _KC_JSON=""
    if [ -n "$_KC_JSON" ]; then
      OAUTH_TOKEN=$(printf '%s' "$_KC_JSON" | jq -r '.claudeAiOauth.accessToken // ""' 2>/dev/null) || OAUTH_TOKEN=""
    fi
  fi
  API_RESP=""
  API_HTTP=0

  _fetch_usage() {
    local _tmp_file
    _tmp_file=$(mktemp "${_SL_PREFIX}-api-XXXXXX")
    API_HTTP=$(curl -s --max-time 5 -o "$_tmp_file" -w "%{http_code}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OAUTH_TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/${VERSION}" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || API_HTTP=0
    API_RESP=$(cat "$_tmp_file" 2>/dev/null) || API_RESP=""
    rm -f "$_tmp_file"
  }

  # Verrou non-bloquant portable : mkdir est atomique sur tous les OS, sans
  # dependance a flock(1) qui n'existe pas sur macOS (le shim le neutralisait
  # en no-op, donc toutes les instances appelaient l'API en parallele). Un
  # verrou plus vieux que 30s est repute orphelin (process mort) et casse :
  # la section critique (curl --max-time 5) ne depasse jamais quelques secondes.
  _usage_lock_acquire() {
    if mkdir "$USAGE_LOCK_DIR" 2>/dev/null; then
      return 0
    fi
    local now lock_mtime
    now=$(date +%s)
    lock_mtime=$(stat -c %Y "$USAGE_LOCK_DIR" 2>/dev/null || echo "$now")
    if [ $((now - lock_mtime)) -gt 30 ]; then
      rmdir "$USAGE_LOCK_DIR" 2>/dev/null || true
      mkdir "$USAGE_LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
  }

  if [ -n "$OAUTH_TOKEN" ]; then
    # Une seule instance appelle l'API, les autres restent sur le fallback cache
    if _usage_lock_acquire; then
      _fetch_usage
      # Sur 429 : activer le backoff de 10 min
      if [ "$API_HTTP" = "429" ]; then
        touch "$USAGE_BACKOFF_FILE" 2>/dev/null || true
      fi
      rmdir "$USAGE_LOCK_DIR" 2>/dev/null || true
    fi
  fi

  # Valider que la reponse contient bien les champs attendus
  if [ "$API_HTTP" = "200" ] && echo "$API_RESP" | jq -e '.five_hour' > /dev/null 2>&1; then
    USAGE_DATA=$(echo "$API_RESP" | jq -r '
      [
        (.five_hour.utilization // 0 | tostring),
        (.five_hour.resets_at // "" | tostring),
        (.seven_day.utilization // 0 | tostring),
        (.seven_day.resets_at // "" | tostring),
        # Quota 7j dedie a Fable : entree weekly_scoped du tableau limits dont
        # le scope model vise Fable. Chaine vide si absente (segment masque).
        ([.limits[]? | select(.kind == "weekly_scoped" and ((.scope.model.display_name // "") | test("fable"; "i")))] | first | .percent // "" | tostring)
      ] | join("|")
    ' 2>/dev/null) || USAGE_DATA="0||0||"
    # Persister dans le fichier durable (survit aux purges /tmp et reboots)
    echo "$USAGE_DATA" > "$USAGE_SESSION_FILE" 2>/dev/null || true
  else
    # API echouee : chaine de fallback
    # 1) Cache /tmp precedent
    # 2) Fichier durable ~/.claude/usage-session
    # 3) Zeros (premier lancement uniquement)
    if [ -n "$PREV_USAGE" ]; then
      USAGE_DATA=$(echo "$PREV_USAGE" | awk -F'|' '{OFS="|"; print $1,$2,$3,$4,$5}') || USAGE_DATA="0||0||"
    elif [ -f "$USAGE_SESSION_FILE" ]; then
      USAGE_DATA=$(cat "$USAGE_SESSION_FILE" 2>/dev/null) || USAGE_DATA="0||0||"
    else
      USAGE_DATA="0||0||"
    fi
  fi

  # --- Couts session : calcul independant (JSONL locaux, pas l'API) ---
  WEEK_SESSION_FILE="$HOME/.claude/week-session"
  RESET_7D_RAW=""
  RESET_5H_RAW=""
  WEEK_START=""

  # Extraire resets_at de l'API si disponible, sinon du cache
  if [ "$API_HTTP" = "200" ] && [ -n "$API_RESP" ]; then
    RESET_7D_RAW=$(echo "$API_RESP" | jq -r '.seven_day.resets_at // ""' 2>/dev/null)
    RESET_5H_RAW=$(echo "$API_RESP" | jq -r '.five_hour.resets_at // ""' 2>/dev/null)
  fi

  # Fallback : utiliser le fichier week-session existant
  if [ -z "$RESET_7D_RAW" ] && [ -f "$WEEK_SESSION_FILE" ]; then
    IFS='|' read -r RESET_7D_RAW WEEK_START < "$WEEK_SESSION_FILE" 2>/dev/null || true
  fi

  # Fallback 5h : cache precedent → fichier durable → approximation
  if [ -z "$RESET_5H_RAW" ] && [ -n "$PREV_USAGE" ]; then
    RESET_5H_RAW=$(echo "$PREV_USAGE" | awk -F'|' '{print $2}')
  fi
  if [ -z "$RESET_5H_RAW" ] && [ -f "$USAGE_SESSION_FILE" ]; then
    RESET_5H_RAW=$(awk -F'|' '{print $2}' "$USAGE_SESSION_FILE" 2>/dev/null)
  fi

  if [ -n "$RESET_7D_RAW" ]; then
    NOW_EPOCH=$(date +%s)

    if [ -f "$WEEK_SESSION_FILE" ] && [ -z "$WEEK_START" ]; then
      IFS='|' read -r STORED_RESET STORED_WEEK_START < "$WEEK_SESSION_FILE" 2>/dev/null || true
      STORED_RESET_EPOCH=$(date -d "$STORED_RESET" +%s 2>/dev/null || echo 0)

      # Regen si : (a) reset stocke depasse, (b) premier run, OU (c) l'API retourne
      # un resets_at different (reset server-side anticipe par Anthropic).
      if [ "$RESET_7D_RAW" != "$STORED_RESET" ] || [ "$NOW_EPOCH" -ge "$STORED_RESET_EPOCH" ] || [ "$STORED_RESET_EPOCH" = "0" ]; then
        WEEK_START=$(date -u -d "$RESET_7D_RAW - 7 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        echo "${RESET_7D_RAW}|${WEEK_START}" > "$WEEK_SESSION_FILE" 2>/dev/null || true
      else
        WEEK_START="$STORED_WEEK_START"
      fi
    elif [ -z "$WEEK_START" ]; then
      WEEK_START=$(date -u -d "$RESET_7D_RAW - 7 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      echo "${RESET_7D_RAW}|${WEEK_START}" > "$WEEK_SESSION_FILE" 2>/dev/null || true
    fi
  fi

  if [ -n "$WEEK_START" ]; then
    # mktemp : fichier temporaire unique par process. Un chemin partage entre
    # instances paralleles se faisait tronquer/supprimer en pleine lecture,
    # ce qui remettait les couts 5h/7j a zero de maniere aleatoire.
    # Purge prealable des orphelins (> 5 min) : une instance tuee en plein
    # calcul (timeout statusline) laisse son mktemp derriere elle. Le filtre
    # par age ne touche jamais le fichier d'une instance vivante. Trailing
    # slash obligatoire : sur macOS /tmp est un symlink (-> private/tmp) que
    # find ne dereference pas sans lui.
    find "${_SL_PREFIX%/*}/" -maxdepth 1 -name "${_SL_PREFIX##*/}-week-raw-*" -mmin +5 -delete 2>/dev/null || true
    WEEK_TMP=$(mktemp "${_SL_PREFIX}-week-raw-XXXXXX")
    # Un enregistrement par LIGNE JSONL (cle reqId nue, la dedup par requete se fait plus
    # bas : derniere ligne = compteurs definitifs), portant un tableau attempts des tentatives
    # facturables. Cas normal : 1 tentative = usage de premier niveau. Cas fallback cote
    # serveur (refus Fable -> modele de repli) : usage.iterations est le registre officiel de
    # facturation, chaque tentative etant facturee au tarif de SON modele ; une tentative sans
    # aucun output (refus avant le premier token) n'est pas facturee, de meme qu'un refus sec
    # (stop_reason refusal sans output) hors fallback -> attempts vide, ce qui neutralise aussi
    # les lignes de streaming intermediaires de la meme requete.
    find "$HOME/.claude/projects/" -name "*.jsonl" -mtime -7 -exec \
      jq -c --arg tw "$WEEK_START" \
        'select(.type == "assistant" and .timestamp != null and .message.model != null and .timestamp > $tw) |
         .message.model as $m | (.message.usage.speed // "standard") as $sp |
         (.message.usage.iterations // []) as $its |
         {ts: .timestamp, reqId: (.requestId // ""),
          web_search: (.message.usage.server_tool_use.web_search_requests // 0),
          attempts: (
            if ($its | length) > 1 then
              [ $its[] | select((.output_tokens // 0) > 0) |
                {model: (.model // $m), speed: $sp,
                 input: (.input_tokens // 0), output: (.output_tokens // 0),
                 cache_5m: (.cache_creation.ephemeral_5m_input_tokens // 0),
                 cache_1h: (.cache_creation.ephemeral_1h_input_tokens // 0),
                 cache_read: (.cache_read_input_tokens // 0)} ]
            elif ((.message.stop_reason // "") == "refusal") and ((.message.usage.output_tokens // 0) == 0) then
              []
            else
              [ .message.usage |
                {model: $m, speed: $sp,
                 input: (.input_tokens // 0), output: (.output_tokens // 0),
                 cache_5m: (.cache_creation.ephemeral_5m_input_tokens // 0),
                 cache_1h: (.cache_creation.ephemeral_1h_input_tokens // 0),
                 cache_read: (.cache_read_input_tokens // 0)} ]
            end)}' {} + > "$WEEK_TMP" 2>/dev/null || true

    # Prix officiels Anthropic (USD / MTok) — verifies le 03/09/2026 sur
    # platform.claude.com/docs/en/about-claude/pricing (Fable 5.1, Fable 5, Opus 5, Opus 4.8,
    # Sonnet 5 inclus). Regle des caches : write 5 min = x1.25 input, write 1h = x2 input,
    # read = x0.1 input, sauf Fable 5.1 / Mythos 5.1 ou read = x0.025.
    # Source UNIQUE partagee par les couts 7j et 5h : les deux jq plus bas l'injectent telle
    # quelle (chaine shell simple quote : pas d'apostrophe dans les commentaires jq).
    # Etape 1 : dedup par requete (le streaming ecrit plusieurs lignes JSONL par requete, seule
    # la derniere porte les compteurs definitifs). Etape 2 : une entree par tentative facturable
    # (attempts), le web search etant rattache a la derniere tentative, celle qui a servi la
    # reponse. Etape 3 : tarif par modele.
    COST_MAP_JQ='
        group_by(.reqId) | map(last) |
        [ .[] | . as $r | $r.attempts | to_entries[] |
          .value + {web_search: (if .key == (($r.attempts | length) - 1) then $r.web_search else 0 end)} ] |
        map(
          .input as $in | .output as $out |
          .cache_5m as $c5 | .cache_1h as $c1 |
          .cache_read as $cr | (.web_search // 0) as $ws |
          # Web search cote serveur : $10 / 1000 requetes quel que soit le modele (web fetch gratuit).
          ($ws * 0.01) +
          if (.model // "" | test("fable-5-1|mythos-5-1")) then
            # Fable 5.1 / Mythos 5.1 (sortis le 01/09/2026) : memes $10/$50 et caches write que
            # Fable 5, mais cache read a $0.25 (x0.025 : seule exception au x0.1). Pas de fast mode.
            ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*0.25) / 1000000
          elif (.model // "" | test("fable|mythos")) then
            # Fable 5 / Mythos 5 : tier flagship, tarif unique $10/$50 (pas de fast mode).
            # Caches = multiplicateurs officiels (x1.25 / x2 / x0.1) sur le tarif input.
            ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*1) / 1000000
          elif (.model // "" | test("opus-5|opus-4-8")) then
            # Opus 5 et Opus 4.8 : memes tarifs, standard $5/$25 et fast $10/$50
            # (fast 3x moins cher que celui de 4.6/4.7 a $30/$150).
            # Caches = multiplicateurs officiels (x1.25 / x2 / x0.1) sur le prix input.
            if .speed == "fast" then
              ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*1) / 1000000
            else
              ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
            end
          elif (.model // "" | test("opus-4-[567]")) then
            # Opus 4.5 / 4.6 / 4.7 : standard $5/$25. Le fast $30/$150 est retire (4.7 renvoie une
            # erreur, 4.6 tourne en standard avec usage.speed = standard, 4.5 ne l a jamais eu) :
            # la sous-branche fast ne sert plus que pour d eventuels messages historiques.
            if .speed == "fast" then
              ($in*30 + $out*150 + $c5*37.5 + $c1*60 + $cr*3) / 1000000
            else
              ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
            end
          elif (.model // "" | test("opus-4-1-|opus-4-2025")) then
            # Opus 4 (claude-opus-4-20250514) et Opus 4.1 (claude-opus-4-1-20250805) : tarif legacy
            # $15/$75. Retires le 15/06 et le 05/08/2026, conserves pour les messages historiques.
            ($in*15 + $out*75 + $c5*18.75 + $c1*30 + $cr*1.5) / 1000000
          elif (.model // "" | test("opus")) then
            # Tout autre Opus (futur opus-4-9, opus-6...) : tarif Opus courant $5/$25 (un opus-5-x
            # est capture plus haut par opus-5, fast compris).
            # Les seuls Opus legacy ($15/$75) sont captures explicitement juste au-dessus.
            ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
          elif (.model // "" | test("haiku")) then
            # Haiku 4.5 : $1/$5. Haiku 3.5 ($0.80/$4) et Haiku 3 sont retires depuis fevrier / avril 2026.
            ($in*1 + $out*5 + $c5*1.25 + $c1*2 + $cr*0.1) / 1000000
          elif (.model // "" | test("sonnet-5")) then
            # Sonnet 5 : $2/$10 definitif. Le tarif de lancement (annonce jusqu au 31/08/2026) est
            # devenu le tarif standard, la hausse a $3/$15 prevue le 01/09/2026 est annulee.
            # Pas de fast mode. Caches = multiplicateurs officiels (x1.25 / x2 / x0.1).
            ($in*2 + $out*10 + $c5*2.5 + $c1*4 + $cr*0.2) / 1000000
          else
            # Fallback general : Sonnet 4.6 / 4.5 et tout ID non reconnu, $3/$15.
            ($in*3 + $out*15 + $c5*3.75 + $c1*6 + $cr*0.3) / 1000000
          end
        ) | add // 0
    '

    if [ -s "$WEEK_TMP" ]; then
      WEEK_COST=$(jq -sc "$COST_MAP_JQ" "$WEEK_TMP" 2>/dev/null) || WEEK_COST="0"
    else
      WEEK_COST="0"
    fi

    # --- Cout 5h : filtrer le meme WEEK_TMP par la fenetre 5h ---
    BLOCK_COST="0"
    BLOCK_START=""
    if [ -n "$RESET_5H_RAW" ]; then
      BLOCK_START=$(date -u -d "$RESET_5H_RAW - 5 hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    else
      # Approximation : fenetre glissante de 5h depuis maintenant
      BLOCK_START=$(date -u -d "now - 5 hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    fi
    if [ -n "$BLOCK_START" ] && [ -s "$WEEK_TMP" ]; then
      BLOCK_COST=$(jq -sc --arg bs "$BLOCK_START" "[ .[] | select(.ts > \$bs) ] | $COST_MAP_JQ" "$WEEK_TMP" 2>/dev/null) || BLOCK_COST="0"
    fi

    rm -f "$WEEK_TMP"
  else
    WEEK_COST="0"
    BLOCK_COST="0"
  fi

  # Fallback : si JSONL echoue, garder les couts precedents
  WEEK_COST="${WEEK_COST:-0}"
  BLOCK_COST="${BLOCK_COST:-0}"
  if [ "$WEEK_COST" = "0" ] && [ -n "$PREV_WEEK_COST" ] && [ "$PREV_WEEK_COST" != "0" ]; then
    WEEK_COST="$PREV_WEEK_COST"
  fi
  if [ "$BLOCK_COST" = "0" ] && [ -n "$PREV_BLOCK_COST" ] && [ "$PREV_BLOCK_COST" != "0" ]; then
    BLOCK_COST="$PREV_BLOCK_COST"
  fi

  USAGE_DATA="${USAGE_DATA}|${WEEK_COST}|${BLOCK_COST}"

  # Toujours ecrire les 7 champs dans le cache
  echo "$USAGE_DATA" > "$USAGE_CACHE" 2>/dev/null || true
else
  USAGE_DATA=$(cat "$USAGE_CACHE" 2>/dev/null) || USAGE_DATA="0||0|||0|0"
fi

# Parsing du cache (garantir 7 champs meme si cache ancien/incomplet)
IFS='|' read -r PCT_5H RESET_5H_ISO PCT_7D RESET_7D_ISO PCT_FABLE WEEK_COST BLOCK_COST <<< "$USAGE_DATA"
WEEK_COST="${WEEK_COST:-0}"
BLOCK_COST="${BLOCK_COST:-0}"
PCT_5H_INT=$(printf '%.0f' "${PCT_5H:-0}" 2>/dev/null) || PCT_5H_INT=0
PCT_7D_INT=$(printf '%.0f' "${PCT_7D:-0}" 2>/dev/null) || PCT_7D_INT=0
# Quota Fable : vide si le compte est sans limite dediee (segment masque)
PCT_FABLE_INT=""
if [ -n "${PCT_FABLE:-}" ]; then
  PCT_FABLE_INT=$(printf '%.0f' "$PCT_FABLE" 2>/dev/null) || PCT_FABLE_INT=""
fi

# --- Mini-barre ▰▱ (10 blocs) ---
mini_bar() {
  local pct=${1:-0} color=$2
  local filled=$((pct / 10))
  [ "$filled" -gt 10 ] && filled=10
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((10 - filled))
  local bar_f="" bar_e=""
  for ((i=0; i<filled; i++)); do bar_f+="▰"; done
  for ((i=0; i<empty; i++)); do bar_e+="▱"; done
  printf '%b' "${color}${bar_f}${DIM}${GRAY}${bar_e}${RST}"
}

# --- Couleur selon seuil ---
usage_color() {
  local pct=$1
  if [ "$pct" -ge 90 ]; then printf '%b' "$BRED"
  elif [ "$pct" -ge 70 ]; then printf '%b' "$BYELLOW"
  else printf '%b' "$BGREEN"; fi
}

COLOR_5H=$(usage_color "$PCT_5H_INT")
COLOR_7D=$(usage_color "$PCT_7D_INT")

# --- Timer 5h ---
NOW_EPOCH=$(date +%s)
if [ -n "$RESET_5H_ISO" ]; then
  RESET_5H_EPOCH=$(date -d "$RESET_5H_ISO" +%s 2>/dev/null || echo 0)
  REMAIN_5H=$((RESET_5H_EPOCH - NOW_EPOCH))
  [ "$REMAIN_5H" -lt 0 ] && REMAIN_5H=0
else
  REMAIN_5H=0
fi

REMAIN_5H_H=$((REMAIN_5H / 3600))
REMAIN_5H_M=$(( (REMAIN_5H % 3600) / 60 ))
if [ "$REMAIN_5H" -gt 0 ]; then
  TIMER_5H="${REMAIN_5H_H}h${REMAIN_5H_M}m"
else
  TIMER_5H="--"
fi

# --- Timer 7j ---
if [ -n "$RESET_7D_ISO" ]; then
  RESET_7D_EPOCH=$(date -d "$RESET_7D_ISO" +%s 2>/dev/null || echo 0)
  REMAIN_7D=$((RESET_7D_EPOCH - NOW_EPOCH))
  [ "$REMAIN_7D" -lt 0 ] && REMAIN_7D=0
else
  REMAIN_7D=0
fi

REMAIN_7D_D=$((REMAIN_7D / 86400))
REMAIN_7D_H=$(( (REMAIN_7D % 86400) / 3600 ))
if [ "$REMAIN_7D_D" -gt 0 ]; then
  TIMER_7D="${REMAIN_7D_D}j ${REMAIN_7D_H}h"
elif [ "$REMAIN_7D" -gt 0 ]; then
  REMAIN_7D_M=$(( (REMAIN_7D % 3600) / 60 ))
  TIMER_7D="${REMAIN_7D_H}h ${REMAIN_7D_M}m"
else
  TIMER_7D="--"
fi

# Assemblage ligne 3
BAR_5H=$(mini_bar "$PCT_5H_INT" "$COLOR_5H")
BAR_7D=$(mini_bar "$PCT_7D_INT" "$COLOR_7D")

# --- Couts formates ---
WEEK_COST_FMT=$(printf '$%.2f' "${WEEK_COST:-0}" 2>/dev/null) || WEEK_COST_FMT='$0.00'
BLOCK_COST_FMT=$(printf '$%.2f' "${BLOCK_COST:-0}" 2>/dev/null) || BLOCK_COST_FMT='$0.00'

BLOCK_SEG="$(printf '%b' "${WHITE}")5h$(printf '%b' "${RST}") ${BAR_5H} $(printf '%b' "${COLOR_5H}${BOLD}")${PCT_5H_INT}%$(printf '%b' "${RST}") $(printf '%b' "${DIM}${CYAN}")${TIMER_5H}$(printf '%b' "${RST}") $(printf '%b' "${BYELLOW}")${BLOCK_COST_FMT}$(printf '%b' "${RST}")"
WEEK_SEG="$(printf '%b' "${WHITE}")7j$(printf '%b' "${RST}") ${BAR_7D} $(printf '%b' "${COLOR_7D}${BOLD}")${PCT_7D_INT}%$(printf '%b' "${RST}") $(printf '%b' "${DIM}${CYAN}")${TIMER_7D}$(printf '%b' "${RST}") $(printf '%b' "${BYELLOW}")${WEEK_COST_FMT}$(printf '%b' "${RST}")"

# --- Segment Fable 7j : juste le pourcentage (limite hebdo dediee au modele) ---
FABLE_SEG=""
if [ -n "$PCT_FABLE_INT" ]; then
  COLOR_FABLE=$(usage_color "$PCT_FABLE_INT")
  FABLE_SEG="$(printf '%b' "${SEP}${GOLD}")Fable$(printf '%b' "${RST}") $(printf '%b' "${COLOR_FABLE}${BOLD}")${PCT_FABLE_INT}%$(printf '%b' "${RST}")"
fi

LINE3="${BLOCK_SEG}$(printf '%b' "${SEP}")${WEEK_SEG}${FABLE_SEG}"

# ============================================================================
# SORTIE
# ============================================================================
printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
printf '%b\n' "$LINE3"
