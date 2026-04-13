#!/bin/bash
# ============================================================================
# Claude Code Statusline — Be Hype / Digiflow Agency
# Developpeur : NeoZiboy
# Statusline 3 lignes : identite/git + metriques/contexte + usage hebdo
# Dependance : jq (sudo apt install -y jq)
# ============================================================================
set -euo pipefail

# --- Lecture du JSON stdin (une seule fois) ---
INPUT=$(cat)

# --- Couleurs ANSI ---
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[37m'
GRAY='\033[90m'

BRED='\033[91m'
BGREEN='\033[92m'
BYELLOW='\033[93m'
BCYAN='\033[96m'
ORANGE='\033[38;5;208m'

# --- Separateur fin │ ---
SEP="${DIM}${GRAY} \xe2\x94\x82 ${RST}"

# --- Extraction JSON en un seul appel jq ---
# Bug fix : eval "" retourne 0, donc le fallback || ne s'execute jamais.
# On stocke la sortie jq d'abord, puis on teste si elle est non-vide.
MODEL_NAME="---"; DIR="."; VERSION="---"; COST=0; DURATION_MS=0
LINES_ADD=0; LINES_REM=0; CTX_PCT=0
AGENT_NAME=""; VIM_MODE=""; TRANSCRIPT_PATH=""

_JQ_OUT=$(echo "$INPUT" | jq -r '
  @sh "MODEL_NAME=\(.model.display_name // "---")",
  @sh "DIR=\(.workspace.current_dir // .cwd // ".")",
  @sh "VERSION=\(.version // "---")",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_REM=\(.cost.total_lines_removed // 0)",
  @sh "CTX_PCT=\(.context_window.used_percentage // 0)",
  @sh "AGENT_NAME=\(.agent.name // "")",
  @sh "VIM_MODE=\(.vim.mode // "")",
  @sh "TRANSCRIPT_PATH=\(.transcript_path // "")"
' 2>/dev/null) || true

[ -n "$_JQ_OUT" ] && eval "$_JQ_OUT"

# --- Nom du projet ---
PROJECT="${DIR##*/}"

# --- Pourcentage contexte (entier) ---
CTX_PCT_INT=$(printf '%.0f' "$CTX_PCT" 2>/dev/null) || CTX_PCT_INT=0

# --- Couleur du modele ---
case "$MODEL_NAME" in
  *Opus*|*opus*)     MC="$MAGENTA" ;;
  *Sonnet*|*sonnet*) MC="$BLUE" ;;
  *Haiku*|*haiku*)   MC="$CYAN" ;;
  *)                 MC="$WHITE" ;;
esac

# ============================================================================
# GIT : cache par repertoire avec TTL de 5 secondes
# ============================================================================
GIT_CACHE_KEY="/tmp/claude-sl-git-$(echo "$DIR" | md5sum 2>/dev/null | cut -d' ' -f1 || echo 'default')"
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
GIT_AVAILABLE=false

if git_cache_stale; then
  if git -C "$DIR" --no-optional-locks rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    GIT_STAGED=$(git -C "$DIR" --no-optional-locks diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    GIT_MODIFIED=$(git -C "$DIR" --no-optional-locks diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    GIT_UNTRACKED=$(git -C "$DIR" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    GIT_AVAILABLE=true
  fi
  echo "${GIT_AVAILABLE}|${GIT_BRANCH}|${GIT_STAGED}|${GIT_MODIFIED}|${GIT_UNTRACKED}" > "$GIT_CACHE_KEY" 2>/dev/null || true
else
  IFS='|' read -r GIT_AVAILABLE GIT_BRANCH GIT_STAGED GIT_MODIFIED GIT_UNTRACKED < "$GIT_CACHE_KEY" 2>/dev/null || true
fi

# --- Segment git ---
GIT_SEGMENT=""
if [ "$GIT_AVAILABLE" = "true" ] && [ -n "$GIT_BRANCH" ]; then
  GIT_SEGMENT="$(printf '%b' "${SEP}${BCYAN}")* ${GIT_BRANCH}$(printf '%b' "${RST}")"

  GIT_PARTS=""
  [ "$GIT_STAGED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${BGREEN}+${GIT_STAGED}${RST}")"
  [ "$GIT_MODIFIED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${BYELLOW}~${GIT_MODIFIED}${RST}")"
  [ "$GIT_UNTRACKED" -gt 0 ] 2>/dev/null && GIT_PARTS="${GIT_PARTS}$(printf '%b' " ${RED}?${GIT_UNTRACKED}${RST}")"

  [ -n "$GIT_PARTS" ] && GIT_SEGMENT="${GIT_SEGMENT}${GIT_PARTS}"
fi

# ============================================================================
# LIGNE 1 : Modele | Projet | Git | Version
# ============================================================================
LINE1="$(printf '%b' "${BOLD}${MC}")${MODEL_NAME}$(printf '%b' "${RST}")"

# Indicateurs Fast mode + Effort level
# 1) settings.json pour fastMode et effortLevel persistant
_SETTINGS=$(jq -r '(.fastMode // false | tostring) + "|" + (.effortLevel // "default")' "$HOME/.claude/settings.json" 2>/dev/null) || _SETTINGS="false|default"
FAST_MODE="${_SETTINGS%%|*}"
EFFORT_LEVEL="${_SETTINGS#*|}"
# 2) Effort reel : lire le JSONL de session (capture le choix via /effort ou /model)
#    Filtre sur <local-command-stdout> pour ignorer le contenu des messages assistant
#    Priorite : "Set effort level to X" > "Effort level: X" > settings.json
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Pattern 1 : "<local-command-stdout>Set effort level to max (this session only)"
  _LIVE_EFFORT=$(grep -oP 'local-command-stdout>Set effort level to \K\w+' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || _LIVE_EFFORT=""
  # Pattern 2 : "<local-command-stdout>Effort level: auto" ou "Current effort level: medium"
  [ -z "$_LIVE_EFFORT" ] && _LIVE_EFFORT=$(grep -ioP 'local-command-stdout>(?:current )?effort level: \K\w+' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || true
  [ -n "$_LIVE_EFFORT" ] && EFFORT_LEVEL="$_LIVE_EFFORT"
fi
if [ "$FAST_MODE" = "true" ]; then
  LINE1="${LINE1} $(printf '%b' "${BYELLOW}\xe2\x9a\xa1${RST}")"
fi

# Barres verticales style signal pour l'effort level
BAR_CHAR="\xe2\x96\x8c"  # ▌ left half block
case "$EFFORT_LEVEL" in
  low)     LINE1="${LINE1} $(printf '%b' "${CYAN}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
  high)    LINE1="${LINE1} $(printf '%b' "${BRED}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${RST}")" ;;
  max)     LINE1="${LINE1} $(printf '%b' "${MAGENTA}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
  *)       LINE1="${LINE1} $(printf '%b' "${BYELLOW}${BAR_CHAR}${BAR_CHAR}${DIM}${GRAY}${BAR_CHAR}${BAR_CHAR}${RST}")" ;;
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

# Git
LINE1="${LINE1}${GIT_SEGMENT}"

# Version
LINE1="${LINE1}$(printf '%b' "${SEP}${DIM}${GRAY}")v${VERSION}$(printf '%b' "${RST}")"

# Status Claude (status.claude.com — cache 60s)
STATUS_CACHE="/tmp/claude-sl-status-cache"
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
# LIGNE 2 : Barre contexte | Session cout | Lignes | Duree
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

# --- Lignes ajoutees/supprimees ---
if [ "$LINES_ADD" -gt 0 ] 2>/dev/null || [ "$LINES_REM" -gt 0 ] 2>/dev/null; then
  LINES_SEGMENT="$(printf '%b' "${BGREEN}")+${LINES_ADD}$(printf '%b' "${RST}") $(printf '%b' "${BRED}")-${LINES_REM}$(printf '%b' "${RST}")"
else
  LINES_SEGMENT="$(printf '%b' "${DIM}${GRAY}")+0 -0$(printf '%b' "${RST}")"
fi

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

# ============================================================================
# INDICATEUR PEAK/OFF-PEAK (heures de pointe Anthropic)
# Peak: lun-ven 5h-11h Pacific Time — limites 5h consommees plus vite
# Reference PT (suit le DST US automatiquement via TZ)
# Source: tweet Thariq @trq212 (26 mars 2026)
# Couleurs: is-claude-nerfed-right-now.vercel.app (#cc785c / #828179)
# ============================================================================
ACCENT='\033[38;5;173m'    # Terracotta ~ #cc785c (normal/boost)
MUTED_FG='\033[38;5;245m'  # Gris mute ~ #828179 (nerfed/peak)

# Heure et jour en Pacific Time (reference Anthropic)
read -r _PT_H _PT_M _PT_DOW <<< "$(TZ='America/Los_Angeles' date +'%-H %-M %u')"

# Peak 5-11 AM PT → heures locales (pour affichage)
_PEAK_S_EP=$(TZ='America/Los_Angeles' date -d 'today 05:00' +%s 2>/dev/null) || _PEAK_S_EP=0
_PEAK_E_EP=$(TZ='America/Los_Angeles' date -d 'today 11:00' +%s 2>/dev/null) || _PEAK_E_EP=0
_LP_S=$(date -d "@$_PEAK_S_EP" +%-H 2>/dev/null) || _LP_S=14
_LP_E=$(date -d "@$_PEAK_E_EP" +%-H 2>/dev/null) || _LP_E=20

if [ "$_PT_DOW" -ge 6 ] || { [ "$_PT_DOW" -eq 5 ] && [ "$_PT_H" -ge 11 ]; }; then
  # --- Weekend (ven 11h PT → dim 23h59 PT) ---
  _NC="$ACCENT"
  _NL="WEEKEND"
  _NI=""
  case "$_PT_DOW" in
    5) _EL=$(( (_PT_H - 11) * 60 + _PT_M )) ;;
    6) _EL=$(( (_PT_H + 13) * 60 + _PT_M )) ;;
    7) _EL=$(( (_PT_H + 37) * 60 + _PT_M )) ;;
  esac
  _TT=3960  # 66h : ven 11h PT → lun 5h PT
  _RM=$(( _TT - _EL ))

elif [ "$_PT_H" -ge 5 ] && [ "$_PT_H" -lt 11 ]; then
  # --- Peak (nerfed) : 5-11 AM PT = 6h ---
  _NC="$MUTED_FG"
  _NL="NERFED"
  _NI="${_LP_S}h-${_LP_E}h"
  _EL=$(( (_PT_H - 5) * 60 + _PT_M ))
  _TT=360
  _RM=$(( _TT - _EL ))

else
  # --- Off-peak (normal) : 11 AM → 5 AM PT = 18h ---
  _NC="$ACCENT"
  _NL="NORMAL"
  _NI="${_LP_E}h-${_LP_S}h"
  if [ "$_PT_H" -ge 11 ]; then
    _EL=$(( (_PT_H - 11) * 60 + _PT_M ))
  else
    _EL=$(( (_PT_H + 13) * 60 + _PT_M ))
  fi
  _TT=1080
  _RM=$(( _TT - _EL ))
fi

[ "$_RM" -lt 0 ] && _RM=0

# Barre de progression 8 blocs
_NP=$(( _EL * 100 / _TT ))
[ "$_NP" -gt 100 ] && _NP=100
_NF=$(( _NP * 8 / 100 ))
[ "$_NF" -gt 8 ] && _NF=8
_NE=$(( 8 - _NF ))
_BF=""; _BE=""
for ((i=0; i<_NF; i++)); do _BF+="█"; done
for ((i=0; i<_NE; i++)); do _BE+="░"; done

# Countdown formate
_RD=$(( _RM / 1440 ))
_RH=$(( (_RM % 1440) / 60 ))
_RMN=$(( _RM % 60 ))
if [ "$_RD" -gt 0 ]; then
  _NCD="${_RD}j${_RH}h"
else
  _NCD="$(printf '%dh%02d' "$_RH" "$_RMN")"
fi

# Assemblage segment nerf
if [ -n "$_NI" ]; then
  NERF_SEGMENT="$(printf '%b' "${_NC}")${_NL}$(printf '%b' "${RST}") $(printf '%b' "${DIM}${GRAY}")${_NI}$(printf '%b' "${RST}") $(printf '%b' "${_NC}")${_BF}$(printf '%b' "${DIM}${GRAY}")${_BE}$(printf '%b' "${RST}") $(printf '%b' "${DIM}")${_NCD}$(printf '%b' "${RST}")"
else
  NERF_SEGMENT="$(printf '%b' "${_NC}")${_NL}$(printf '%b' "${RST}") $(printf '%b' "${_NC}")${_BF}$(printf '%b' "${DIM}${GRAY}")${_BE}$(printf '%b' "${RST}") $(printf '%b' "${DIM}")${_NCD}$(printf '%b' "${RST}")"
fi

# Assemblage ligne 2
LINE2="${BAR_SEGMENT}$(printf '%b' "${SEP}")${SESSION_SEGMENT}$(printf '%b' "${SEP}")${LINES_SEGMENT}$(printf '%b' "${SEP}")${DURATION_SEGMENT}$(printf '%b' "${SEP}")${NERF_SEGMENT}"

# ============================================================================
# LIGNE 3 : Usage reel via API OAuth Anthropic (5h + 7j)
# Source : /api/oauth/usage — donnees officielles du plan Max20
# Cache dans /tmp avec TTL de 300s + backoff 600s sur 429 + flock multi-instances
# ============================================================================
USAGE_CACHE="/tmp/claude-sl-usage-cache"
USAGE_CACHE_TTL=300
USAGE_BACKOFF_FILE="/tmp/claude-sl-usage-backoff"
USAGE_BACKOFF_TTL=600
USAGE_LOCK="/tmp/claude-sl-usage.lock"
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

  # --- Appel API OAuth usage (flock : un seul process a la fois) ---
  OAUTH_TOKEN=$(jq -r '.claudeAiOauth.accessToken // ""' "$HOME/.claude/.credentials.json" 2>/dev/null) || OAUTH_TOKEN=""
  API_RESP=""
  API_HTTP=0

  _fetch_usage() {
    local _tmp_file
    _tmp_file=$(mktemp /tmp/claude-sl-api-XXXXXX)
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

  if [ -n "$OAUTH_TOKEN" ]; then
    # flock -n : non-bloquant, une seule instance appelle l'API
    exec 9>"$USAGE_LOCK"
    if flock -n 9; then
      _fetch_usage
      # Sur 429 : activer le backoff de 10 min
      if [ "$API_HTTP" = "429" ]; then
        touch "$USAGE_BACKOFF_FILE" 2>/dev/null || true
      fi
    fi
    exec 9>&-
  fi

  # Valider que la reponse contient bien les champs attendus
  if [ "$API_HTTP" = "200" ] && echo "$API_RESP" | jq -e '.five_hour' > /dev/null 2>&1; then
    USAGE_DATA=$(echo "$API_RESP" | jq -r '
      [
        (.five_hour.utilization // 0 | tostring),
        (.five_hour.resets_at // "" | tostring),
        (.seven_day.utilization // 0 | tostring),
        (.seven_day.resets_at // "" | tostring),
        ""
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
      USAGE_DATA=$(echo "$PREV_USAGE" | awk -F'|' '{OFS="|"; print $1,$2,$3,$4,""}') || USAGE_DATA="0||0||"
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

      if [ "$NOW_EPOCH" -ge "$STORED_RESET_EPOCH" ] || [ "$STORED_RESET_EPOCH" = "0" ]; then
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
    WEEK_TMP="/tmp/claude-sl-week-raw.jsonl"
    find "$HOME/.claude/projects/" -name "*.jsonl" -mtime -7 -exec \
      jq -c --arg tw "$WEEK_START" \
        'select(.type == "assistant" and .timestamp != null and .message.model != null and .timestamp > $tw) |
         (.message.usage.input_tokens // 0) as $in |
         (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) as $c5 |
         (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) as $c1 |
         (.message.usage.cache_read_input_tokens // 0) as $cr |
         {ts: .timestamp, reqId: .requestId, model: .message.model,
          speed: (.message.usage.speed // "standard"),
          input: $in, output: (.message.usage.output_tokens // 0),
          cache_5m: $c5, cache_1h: $c1, cache_read: $cr}' {} + > "$WEEK_TMP" 2>/dev/null || true

    if [ -s "$WEEK_TMP" ]; then
      # Prix officiels Anthropic (USD / MTok) — mars 2026
      WEEK_COST=$(jq -sc '
        group_by(.reqId) | map(last) |
        map(
          .input as $in | .output as $out |
          .cache_5m as $c5 | .cache_1h as $c1 |
          .cache_read as $cr |
          if (.model // "" | test("opus-4-[56]")) then
            if .speed == "fast" then
              ($in*30 + $out*150 + $c5*37.5 + $c1*60 + $cr*3) / 1000000
            else
              ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
            end
          elif (.model // "" | test("opus")) then
            ($in*15 + $out*75 + $c5*18.75 + $c1*30 + $cr*1.5) / 1000000
          elif (.model // "" | test("haiku")) then
            ($in*1 + $out*5 + $c5*1.25 + $c1*2 + $cr*0.1) / 1000000
          else
            ($in*3 + $out*15 + $c5*3.75 + $c1*6 + $cr*0.3) / 1000000
          end
        ) | add // 0
      ' "$WEEK_TMP" 2>/dev/null) || WEEK_COST="0"
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
      BLOCK_COST=$(jq -sc --arg bs "$BLOCK_START" '
        [ .[] | select(.ts > $bs) ] |
        group_by(.reqId) | map(last) |
        map(
          .input as $in | .output as $out |
          .cache_5m as $c5 | .cache_1h as $c1 |
          .cache_read as $cr |
          if (.model // "" | test("opus-4-[56]")) then
            if .speed == "fast" then
              ($in*30 + $out*150 + $c5*37.5 + $c1*60 + $cr*3) / 1000000
            else
              ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
            end
          elif (.model // "" | test("opus")) then
            ($in*15 + $out*75 + $c5*18.75 + $c1*30 + $cr*1.5) / 1000000
          elif (.model // "" | test("haiku")) then
            ($in*1 + $out*5 + $c5*1.25 + $c1*2 + $cr*0.1) / 1000000
          else
            ($in*3 + $out*15 + $c5*3.75 + $c1*6 + $cr*0.3) / 1000000
          end
        ) | add // 0
      ' "$WEEK_TMP" 2>/dev/null) || BLOCK_COST="0"
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
IFS='|' read -r PCT_5H RESET_5H_ISO PCT_7D RESET_7D_ISO _UNUSED WEEK_COST BLOCK_COST <<< "$USAGE_DATA"
WEEK_COST="${WEEK_COST:-0}"
BLOCK_COST="${BLOCK_COST:-0}"
PCT_5H_INT=$(printf '%.0f' "${PCT_5H:-0}" 2>/dev/null) || PCT_5H_INT=0
PCT_7D_INT=$(printf '%.0f' "${PCT_7D:-0}" 2>/dev/null) || PCT_7D_INT=0

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

LINE3="${BLOCK_SEG}$(printf '%b' "${SEP}")${WEEK_SEG}"

# ============================================================================
# SORTIE
# ============================================================================
printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
printf '%b\n' "$LINE3"
