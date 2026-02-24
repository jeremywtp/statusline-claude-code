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

# --- Separateur fin │ ---
SEP="${DIM}${GRAY} \xe2\x94\x82 ${RST}"

# --- Extraction JSON en un seul appel jq ---
# Bug fix : eval "" retourne 0, donc le fallback || ne s'execute jamais.
# On stocke la sortie jq d'abord, puis on teste si elle est non-vide.
MODEL_NAME="---"; DIR="."; VERSION="---"; COST=0; DURATION_MS=0
LINES_ADD=0; LINES_REM=0; CTX_PCT=0; CTX_INPUT=0; CTX_OUTPUT=0
EXCEEDS_200K=false; AGENT_NAME=""; VIM_MODE=""

_JQ_OUT=$(echo "$INPUT" | jq -r '
  @sh "MODEL_NAME=\(.model.display_name // "---")",
  @sh "DIR=\(.workspace.current_dir // .cwd // ".")",
  @sh "VERSION=\(.version // "---")",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_REM=\(.cost.total_lines_removed // 0)",
  @sh "CTX_PCT=\(.context_window.used_percentage // 0)",
  @sh "CTX_INPUT=\(.context_window.total_input_tokens // 0)",
  @sh "CTX_OUTPUT=\(.context_window.total_output_tokens // 0)",
  @sh "EXCEEDS_200K=\(.exceeds_200k_tokens // false)",
  @sh "AGENT_NAME=\(.agent.name // "")",
  @sh "VIM_MODE=\(.vim.mode // "")"
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

# --- Formatage tokens lisible (1.2k, 45.3k, 1.2M) ---
format_tokens() {
  local n=${1:-0}
  n=${n%.*}  # Tronquer si float
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf '%.1fM' "$(echo "$n / 1000000" | bc -l 2>/dev/null)" || printf '%dM' "$((n / 1000000))"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf '%.1fk' "$(echo "$n / 1000" | bc -l 2>/dev/null)" || printf '%dk' "$((n / 1000))"
  else
    printf '%d' "$n" 2>/dev/null || printf '0'
  fi
}

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

# ============================================================================
# LIGNE 2 : Barre contexte | Session cout + tokens | Lignes | Duree
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

# Alerte >200k tokens
WARN_200K=""
[ "$EXCEEDS_200K" = "true" ] && WARN_200K=" $(printf '%b' "${BRED}!${RST}")"

BAR_SEGMENT="$(printf '%b' "${BAR_COLOR}")${BAR_FILLED}$(printf '%b' "${DIM}${GRAY}")${BAR_EMPTY}$(printf '%b' "${RST}") ${PCT_LABEL}${WARN_200K}"

# --- Session : cout + tokens ---
COST_FMT=$(printf '$%.2f' "$COST" 2>/dev/null) || COST_FMT='$0.00'
CTX_INPUT=${CTX_INPUT%.*}; CTX_OUTPUT=${CTX_OUTPUT%.*}
TOTAL_TOK=$((CTX_INPUT + CTX_OUTPUT))
TOK_FMT=$(format_tokens "$TOTAL_TOK")
SESSION_SEGMENT="$(printf '%b' "${YELLOW}")${COST_FMT}$(printf '%b' "${RST}") $(printf '%b' "${DIM}${GRAY}")${TOK_FMT}$(printf '%b' "${RST}")"

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

# Assemblage ligne 2
LINE2="${BAR_SEGMENT}$(printf '%b' "${SEP}")${SESSION_SEGMENT}$(printf '%b' "${SEP}")${LINES_SEGMENT}$(printf '%b' "${SEP}")${DURATION_SEGMENT}"

# ============================================================================
# LIGNE 3 : Usage reel via API OAuth Anthropic (5h + 7j)
# Source : /api/oauth/usage — donnees officielles du plan Max20
# Cache dans /tmp avec TTL de 60 secondes
# ============================================================================
USAGE_CACHE="/tmp/claude-sl-usage-cache"
USAGE_CACHE_TTL=60

usage_cache_stale() {
  [ ! -f "$USAGE_CACHE" ] && return 0
  local now file_age
  now=$(date +%s)
  file_age=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)
  [ $((now - file_age)) -gt "$USAGE_CACHE_TTL" ]
}

if usage_cache_stale; then
  # Lire le token OAuth
  OAUTH_TOKEN=$(jq -r '.claudeAiOauth.accessToken // ""' "$HOME/.claude/.credentials.json" 2>/dev/null) || OAUTH_TOKEN=""
  API_RESP=""

  if [ -n "$OAUTH_TOKEN" ]; then
    API_RESP=$(curl -sf --max-time 5 \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OAUTH_TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || API_RESP=""
  fi

  if [ -n "$API_RESP" ]; then
    USAGE_DATA=$(echo "$API_RESP" | jq -r '
      [
        (.five_hour.utilization // 0 | tostring),
        (.five_hour.resets_at // "" | tostring),
        (.seven_day.utilization // 0 | tostring),
        (.seven_day.resets_at // "" | tostring),
        ""
      ] | join("|")
    ' 2>/dev/null) || USAGE_DATA="0||0||"

    # Cout hebdo : calculer le debut de la fenetre 7j depuis resets_at
    WEEK_START=""
    RESET_7D_RAW=$(echo "$API_RESP" | jq -r '.seven_day.resets_at // ""' 2>/dev/null)
    if [ -n "$RESET_7D_RAW" ]; then
      WEEK_START=$(date -u -d "$RESET_7D_RAW - 7 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    fi

    if [ -n "$WEEK_START" ]; then
      # Fichier temporaire pour eviter les problemes de pipe avec find -exec
      WEEK_TMP="/tmp/claude-sl-week-raw.jsonl"
      find "$HOME/.claude/projects/" -name "*.jsonl" -mtime -7 2>/dev/null -exec \
        jq -c --arg tw "$WEEK_START" \
          'select(.type == "assistant" and .timestamp != null and .message.model != null and .timestamp > $tw) |
           {reqId: .requestId, model: .message.model,
            input: (.message.usage.input_tokens // 0),
            output: (.message.usage.output_tokens // 0),
            cache_write: (.message.usage.cache_creation_input_tokens // 0),
            cache_read: (.message.usage.cache_read_input_tokens // 0)}' {} \; > "$WEEK_TMP" 2>/dev/null || true

      if [ -s "$WEEK_TMP" ]; then
        WEEK_COST=$(jq -sc '
          group_by(.reqId) | map(last) |
          group_by(.model) | map(
            (map(.input) | add) as $in |
            (map(.output) | add) as $out |
            (map(.cache_write) | add) as $cw |
            (map(.cache_read) | add) as $cr |
            if (.[0].model // "" | test("opus")) then
              ($in * 15 + $out * 75 + $cw * 18.75 + $cr * 1.5) / 1000000
            elif (.[0].model // "" | test("haiku")) then
              ($in * 0.8 + $out * 4 + $cw * 1 + $cr * 0.08) / 1000000
            else
              ($in * 3 + $out * 15 + $cw * 3.75 + $cr * 0.3) / 1000000
            end
          ) | add // 0
        ' "$WEEK_TMP" 2>/dev/null) || WEEK_COST="0"
      else
        WEEK_COST="0"
      fi
      rm -f "$WEEK_TMP"
    else
      WEEK_COST="0"
    fi

    USAGE_DATA="${USAGE_DATA}|${WEEK_COST}"
  else
    USAGE_DATA="0||0|||0"
  fi

  echo "$USAGE_DATA" > "$USAGE_CACHE" 2>/dev/null || true
else
  USAGE_DATA=$(cat "$USAGE_CACHE" 2>/dev/null) || USAGE_DATA="0||0|||0"
fi

# Parsing du cache
IFS='|' read -r PCT_5H RESET_5H_ISO PCT_7D RESET_7D_ISO _UNUSED WEEK_COST <<< "$USAGE_DATA"
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

# --- Cout hebdo formate ---
WEEK_COST_FMT=$(printf '$%.2f' "${WEEK_COST:-0}" 2>/dev/null) || WEEK_COST_FMT='$0.00'

BLOCK_SEG="$(printf '%b' "${WHITE}")5h$(printf '%b' "${RST}") ${BAR_5H} $(printf '%b' "${COLOR_5H}${BOLD}")${PCT_5H_INT}%$(printf '%b' "${RST}") $(printf '%b' "${DIM}${CYAN}")${TIMER_5H}$(printf '%b' "${RST}")"
WEEK_SEG="$(printf '%b' "${WHITE}")7j$(printf '%b' "${RST}") ${BAR_7D} $(printf '%b' "${COLOR_7D}${BOLD}")${PCT_7D_INT}%$(printf '%b' "${RST}") $(printf '%b' "${BYELLOW}")${WEEK_COST_FMT}$(printf '%b' "${RST}") $(printf '%b' "${DIM}${CYAN}")${TIMER_7D}$(printf '%b' "${RST}")"

LINE3="${BLOCK_SEG}$(printf '%b' "${SEP}")${WEEK_SEG}"

# ============================================================================
# SORTIE
# ============================================================================
printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
printf '%b\n' "$LINE3"
