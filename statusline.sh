#!/bin/bash
# ============================================================================
# Claude Code Statusline — Be Hype / Digiflow Agency
# Developpeur : NeoZiboy
# Statusline 3 lignes : identite/git + metriques/contexte + usage hebdo
# Sur un serveur (fichier /etc/claude-statusline.conf) : trois lignes aussi, la
# première dit où l'on est et comment va la machine.
# Dependance : jq (sudo apt install -y jq)
# ============================================================================
set -euo pipefail

# Une statusline ne doit jamais s'arrêter en route : un code de sortie non nul ou une sortie
# vide laisse la barre vide. La ligne « set -euo pipefail » ci-dessus reste telle quelle
# (l'installeur macOS s'y accroche pour insérer son shim), puis errexit et pipefail sont
# levés : chaque commande qui peut échouer est traitée là où elle est appelée.
set +e +o pipefail
# Tout fichier créé ici n'est lisible que par son propriétaire, quel que soit le masque de la
# session (0002 ou 0007 sur les serveurs, où www-data partage parfois le groupe du compte).
# Le masque d'origine est gardé pour le seul `git fetch` des postes ; il est lu dans /proc quand
# il existe (aucun sous-processus à lancer), sinon demandé au shell.
_UMASK_SESSION=""
if [ -r /proc/self/status ]; then
  while read -r _k _v; do
    if [ "$_k" = "Umask:" ]; then _UMASK_SESSION=$_v; break; fi
  done < /proc/self/status
fi
[[ $_UMASK_SESSION =~ ^[0-7]{3,4}$ ]] || _UMASK_SESSION=$(umask)
umask 077
# Séparateur décimal « . » pour printf '%.Nf' (sinon échec en locale fr_FR, qui attend « 8,0 »
# et fait tomber tous les pourcentages et coûts à 0).
export LC_NUMERIC=C

# --- Jetons : hors de l'environnement dès la première ligne utile ---
# Le jeton peut arriver par l'environnement (CLAUDE_CODE_OAUTH_TOKEN, posé par ce qui lance
# la session). Il est gardé dans une variable du script puis retiré de
# l'environnement : aucun programme lancé d'ici (git, jq, pm2, ps, curl de statut) n'en hérite.
# Seul le rafraîchissement des quotas le reçoit, par son entrée standard.
_ENV_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_REFRESH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN 2>/dev/null

# --- Couleurs ANSI ---
# Palette 256 (codes >= 16) pour un rendu identique sur tous les terminaux.
# Les codes 16-couleurs (30-37 / 90-97) sont remappes par certains terminaux
# (cmux, Solarized, etc.) ce qui faisait ressortir le vert en jaune et le
# violet en violet pale. Les codes 256 sont fixes, pas configurables.
# Les variables portent le VRAI caractère d'échappement : la sortie finale s'écrit avec
# printf '%s', qui n'interprète rien. Un nom de dossier ou de branche contenant « \033 »
# s'affiche donc tel quel au lieu d'être exécuté par le terminal.
E=$'\033'
RST="${E}[0m"
BOLD="${E}[1m"
DIM="${E}[2m"

RED="${E}[38;5;196m"
GREEN="${E}[38;5;40m"
YELLOW="${E}[38;5;220m"
BLUE="${E}[38;5;33m"
MAGENTA="${E}[38;5;129m"
CYAN="${E}[38;5;39m"
WHITE="${E}[38;5;255m"
GRAY="${E}[38;5;244m"

BRED="${E}[38;5;203m"
BGREEN="${E}[38;5;82m"
BYELLOW="${E}[38;5;227m"
BCYAN="${E}[38;5;51m"
ORANGE="${E}[38;5;208m"
UMAGENTA="${E}[38;5;201m"  # magenta vif — reserve a ultracode (effort "ultra")
GOLD="${E}[38;5;214m"      # or/ambre — reserve a Fable / Mythos (5, 5.1 et 5.2, tier flagship au-dessus d'Opus)

# --- Separateur fin │ ---
SEP="${DIM}${GRAY} │ ${RST}"

# ============================================================================
# OUTILS (sans sous-processus : rien ici ne coûte un fork)
# ============================================================================

# Heure courante : variable de bash 5, sinon date.
if [ -n "${EPOCHSECONDS:-}" ]; then NOW=$EPOCHSECONDS; else NOW=$(date +%s); fi

# Entier positif borné, sans zéro de tête (lu en octal par bash) : seul format admis avant toute opération arithmétique. Bash évalue
# une chaîne passée à $(( )) comme une expression, « a[$(commande)] » compris : rien de ce
# qui vient d'un fichier ou de l'entrée n'y entre sans être passé par ici.
is_uint() { [[ ${1:-} =~ ^(0|[1-9][0-9]{0,14})$ ]]; }
# Nombre décimal positif tel que jq l'écrit : jusqu'à 17 chiffres après la virgule
# (0.21550000000000002), notation scientifique comprise (1.5e-05).
is_num() { [[ ${1:-} =~ ^[0-9]{1,15}(\.[0-9]{1,30})?([eE][-+]?[0-9]{1,2})?$ ]]; }

# round_to <variable> <nombre> [défaut] : arrondi à l'entier, 0 (ou le défaut) si invalide.
round_to() {
  local -n _rt_out=$1
  local d=${3-0}
  if is_num "${2:-}"; then printf -v _rt_out '%.0f' "$2" 2>/dev/null; else _rt_out=$d; return 0; fi
  is_uint "$_rt_out" || _rt_out=$d
}

# clean <variable> : retire les caractères de contrôle (C0, DEL, C1 encodés en UTF-8). Aucune
# séquence d'échappement ne survit, d'où qu'elle vienne (entrée, git, fichier de cache, réglage).
clean() {
  local -n _cl_v=$1
  local LC_ALL=C
  _cl_v=${_cl_v//[$'\001'-$'\037'$'\177']/}
  _cl_v=${_cl_v//$'\302'[$'\200'-$'\237']/}
}

# vlen <variable> <texte> : largeur affichée. Retire les couleurs, puis compte les points de
# code (en locale C, un point de code = un octet qui n'est pas un octet de continuation UTF-8),
# quel que soit le réglage de langue de la session.
vlen() {
  local -n _vl_out=$1
  local LC_ALL=C s=$2 plain=""
  # Découpe sur chaque « ESC[ … m » par retraits de préfixe : quelques microsecondes par
  # couleur. (Un motif étendu dans ${s//…/} coûtait 40 ms sur une ligne : écarté.)
  while [[ $s == *$'\033['* ]]; do
    plain+=${s%%$'\033['*}
    s=${s#*$'\033['}
    s=${s#*m}
  done
  plain+=$s
  plain=${plain//[$'\200'-$'\277']/}
  _vl_out=${#plain}
}

# trunc <variable> <longueur> : coupe à N caractères affichés, sans casser un caractère
# accentué, et marque la coupe par « … ».
trunc() {
  local -n _tr_v=$1
  local max=$2 n
  vlen n "$_tr_v"
  [ "$n" -le "$max" ] && return 0
  local LC_ALL=C out="" i=0 count=0 ch len=${#_tr_v}
  while [ "$i" -lt "$len" ]; do
    ch=${_tr_v:i:1}
    case $ch in
      [$'\200'-$'\277']) ;;
      *) count=$((count + 1)); [ "$count" -ge "$max" ] && break ;;
    esac
    out+=$ch
    i=$((i + 1))
  done
  _tr_v="${out}…"
}

# fit <variable> <largeur max> : assemble les segments de SEGS[] avec le séparateur. Si la
# ligne dépasse, retire un à un les segments les moins importants (PRIOS[] : 0 = jamais
# retiré, plus le chiffre est haut, plus tôt le segment part). Rien n'est coupé au milieu.
fit() {
  local -n _ft_out=$1
  local max=$2 line w i drop dropprio
  while :; do
    line=""
    for i in "${!SEGS[@]}"; do
      [ -n "${SEGS[$i]}" ] || continue
      if [ -n "$line" ]; then line+="${SEP}${SEGS[$i]}"; else line="${SEGS[$i]}"; fi
    done
    vlen w "$line"
    [ "$w" -le "$max" ] && break
    drop=-1; dropprio=0
    for i in "${!SEGS[@]}"; do
      [ -n "${SEGS[$i]}" ] || continue
      if [ "${PRIOS[$i]:-0}" -ge "$dropprio" ] && [ "${PRIOS[$i]:-0}" -gt 0 ]; then
        drop=$i; dropprio=${PRIOS[$i]}
      fi
    done
    [ "$drop" -ge 0 ] || break
    SEGS[$drop]=""
  done
  _ft_out=$line
}

# Commande bornée dans le temps quand `timeout` existe (git sur un gros dépôt, pm2, df sur un
# montage réseau figé) : une statusline lente est annulée par Claude Code et reste vide.
_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then _TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then _TIMEOUT=gtimeout; fi
borne() {
  local s=$1; shift
  if [ -n "$_TIMEOUT" ]; then "$_TIMEOUT" "$s" "$@"; else "$@"; fi
}

# ============================================================================
# PROFIL, CACHE, RÉGLAGES
# ============================================================================

# --- Dossier du profil Claude : ~/.claude par defaut, ou celui d'un autre compte ---
# Un second compte tourne avec CLAUDE_CONFIG_DIR=<profil> (ex. ~/.claude-compte2). Ses
# identifiants Linux (.credentials.json) et ses reglages sont lus dans CE dossier ; ses JSONL
# aussi (projects/, souvent un lien symbolique vers ~/.claude/projects quand l'historique est
# partage entre comptes).
_HOME="${HOME:-}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$_HOME/.claude}"

# --- Cache : un dossier privé par profil, jamais /tmp ---
# /tmp est commun à tous les comptes d'un serveur (parfois des dizaines) : un nom de fichier
# prévisible s'y prépare à l'avance par n'importe qui. Le cache vit sous ~/.cache, dans un
# dossier 700 que ce compte possède ; il est refusé s'il appartient à un autre ou si c'est un
# lien. Son contenu reste relu comme une donnée douteuse (nombres validés, texte nettoyé).
_PROFILE_KEY="defaut"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  _PROFILE_KEY=${CLAUDE_CONFIG_DIR//[^A-Za-z0-9]/_}
  # (${var: -120} rend une chaîne vide quand la valeur est plus courte : ne couper que si besoin)
  [ "${#_PROFILE_KEY}" -gt 120 ] && _PROFILE_KEY=${_PROFILE_KEY: -120}
  [ -n "$_PROFILE_KEY" ] || _PROFILE_KEY="defaut"
fi
CACHE_DIR=""
if [ -n "$_HOME" ]; then
  _CD="${XDG_CACHE_HOME:-$_HOME/.cache}/claude-statusline/$_PROFILE_KEY"
  [ -d "$_CD" ] || mkdir -p -m 700 "$_CD" 2>/dev/null
  if [ -d "$_CD" ] && [ ! -L "$_CD" ] && [ -O "$_CD" ] && [ -w "$_CD" ]; then CACHE_DIR=$_CD; fi
fi

# --- Réglages : fichier « clé=valeur », LU, jamais exécuté ---
# /etc/claude-statusline.conf (root) fait d'une machine un serveur : il nomme la machine et
# dit ce qu'on y surveille. S'il existe, lui seul compte (le badge du serveur est un repère de
# sécurité : un fichier du dossier personnel ne doit pas pouvoir le maquiller). Sans lui,
# ~/.config/claude-statusline.conf permet les mêmes réglages sur un poste.
# Clés : SERVEUR, NIVEAU (critique|prod|outils|secours), DISQUES (points de montage séparés
# par des espaces), et quatre interrupteurs à 0 ou 1 : AUTOFETCH, STATUT_CLAUDE, COUTS, QUOTA_API.
SRV_LABEL=""; SRV_TIER=""; SRV_DISKS="/"
OPT_AUTOFETCH=""; OPT_STATUS=""; OPT_COSTS=""; OPT_QUOTA_API=""
read_conf() {
  local f=$1 k v
  [ -f "$f" ] && [ -r "$f" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k=${k//[[:space:]]/}
    case $k in ''|'#'*) continue ;; esac
    v=${v%$'\r'}; v=${v#\"}; v=${v%\"}
    # Valeur : ASCII imprimable sans caractère de commande, 60 caractères au plus.
    [[ $v =~ ^[A-Za-z0-9\ ._,:/+@%-]{0,60}$ ]] || continue
    case $k in
      SERVEUR) SRV_LABEL=$v ;;
      NIVEAU) case $v in critique|prod|outils|secours) SRV_TIER=$v ;; esac ;;
      DISQUES) SRV_DISKS=$v ;;
      AUTOFETCH) case $v in 0|1) OPT_AUTOFETCH=$v ;; esac ;;
      STATUT_CLAUDE) case $v in 0|1) OPT_STATUS=$v ;; esac ;;
      COUTS) case $v in 0|1) OPT_COSTS=$v ;; esac ;;
      QUOTA_API) case $v in 0|1) OPT_QUOTA_API=$v ;; esac ;;
    esac
  done < "$f"
  return 0
}
# Chemins du système lus par ce script (regroupés ici : le banc d'essai les redirige).
P_CONF=/etc/claude-statusline.conf
P_PROC=/proc
read_conf "$P_CONF" || { [ -n "$_HOME" ] && read_conf "${XDG_CONFIG_HOME:-$_HOME/.config}/claude-statusline.conf"; }
SRV_MODE=0
[ -n "$SRV_LABEL" ] && SRV_MODE=1
# Sur un serveur, aucun `git fetch` automatique : il écrit dans .git avec le masque de la
# session (fichiers ouverts au groupe), prend des verrous qu'un déploiement en cours attend,
# et sort sur le réseau avec les identifiants GitHub du serveur. Sur un poste, il reste actif.
if [ -z "$OPT_AUTOFETCH" ]; then
  if [ "$SRV_MODE" = 1 ]; then OPT_AUTOFETCH=0; else OPT_AUTOFETCH=1; fi
fi
# Sur un serveur, par défaut, pas de montants en dollars : les comptes des serveurs sont des
# abonnements partagés, ces chiffres ne correspondent à aucune facture ; du même coup aucune
# transcription n'y est lue. Le quota Fable (API des quotas) et le point de statut restent
# affichés partout ; QUOTA_API=0 et STATUT_CLAUDE=0 les coupent, et avec eux tout appel réseau.
[ -n "$OPT_STATUS" ] || OPT_STATUS=1
[ -n "$OPT_QUOTA_API" ] || OPT_QUOTA_API=1
if [ -z "$OPT_COSTS" ]; then
  if [ "$SRV_MODE" = 1 ]; then OPT_COSTS=0; else OPT_COSTS=1; fi
fi

# Durées de vie des caches (secondes).
USAGE_TTL=300; USAGE_BACKOFF_TTL=600; STATUS_TTL=60; SERVER_TTL=45; GIT_TTL=5; FETCH_TTL=300

# cache_line <variable> <nom> : première ligne d'un fichier du cache (vide si absent ou lien).
cache_line() {
  local -n _cg_out=$1
  _cg_out=""
  [ -n "$CACHE_DIR" ] || return 1
  local f="$CACHE_DIR/$2"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  IFS= read -r _cg_out < "$f" 2>/dev/null
  [ -n "$_cg_out" ]
}

# cache_put <nom> <contenu> : écriture puis renommage, pour qu'un lecteur ne voie jamais un
# fichier à moitié écrit (réservé au rafraîchissement d'arrière-plan : mv coûte un fork).
cache_put() {
  [ -n "$CACHE_DIR" ] || return 1
  local tmp="$CACHE_DIR/.$1.$$"
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE_DIR/$1" 2>/dev/null
}

# cache_epoch <variable> <nom> : date d'écriture d'un cache (2e champ), 0 s'il est absent.
cache_epoch() {
  local -n _ce_out=$1
  local _cl="" _cv="" _cep="" _cr=""
  _ce_out=0
  cache_line _cl "$2" || return 1
  IFS='|' read -r _cv _cep _cr <<< "$_cl"
  [ "$_cv" = v3 ] && is_uint "$_cep" && _ce_out=$_cep
}
# is_stale <nom> <durée> : vrai si le cache manque, est trop vieux, ou daté dans le futur.
is_stale() {
  local e
  cache_epoch e "$1"
  [ "$e" -gt "$NOW" ] || [ $((NOW - e)) -gt "$2" ]
}

# --- Largeur disponible ---
# Claude Code donne la largeur du terminal dans COLUMNS. Chaque ligne s'y adapte : les segments
# les moins importants partent en premier, rien n'est coupé au milieu (volet étroit d'un terminal
# web, par exemple). Sans COLUMNS, aucune limite : rendu complet, comme avant.
MAXW=9999
if is_uint "${COLUMNS:-}" && [ "$COLUMNS" -ge 30 ]; then MAXW=$((COLUMNS - 4)); fi


# ============================================================================
# LIGNE SERVEUR (en tête, seulement si /etc/claude-statusline.conf nomme la machine)
# ============================================================================
# Où l'on est, puis comment va la machine. Au calme, tout est gris : seul ce qui demande de
# l'attention prend une couleur, et c'est ce qui reste affiché quand la place manque.
ligne_serveur() {
  LINE0=""
  [ "$SRV_MODE" = 1 ] || return 0
  SEGS=(); PRIOS=(); LEVELS=()
  case $SRV_TIER in
    critique) _bg="${E}[48;5;160m${E}[38;5;231m" ;;
    prod)     _bg="${E}[48;5;208m${E}[38;5;16m" ;;
    outils)   _bg="${E}[48;5;33m${E}[38;5;231m" ;;
    secours)  _bg="${E}[48;5;240m${E}[38;5;231m" ;;
    *)        _bg="${E}[48;5;37m${E}[38;5;16m" ;;
  esac
  _badge="${_bg}${BOLD} ${SRV_LABEL} ${RST}"
  # Qui tient la session : nom de l'opérateur, quand ce qui lance la session le transmet.
  if [[ ${STATUSLINE_OPERATOR:-} =~ ^[A-Za-z0-9._-]{1,24}$ ]]; then _badge+=" ${WHITE}${STATUSLINE_OPERATOR}${RST}"; fi
  SEGS+=("$_badge"); PRIOS+=(0); LEVELS+=(0)

  # item <texte> <niveau 0 calme | 1 à surveiller | 2 alerte> <priorité au calme> [priorité en alerte]
  # Priorité : plus le chiffre est haut, plus tôt le segment part quand la place manque. Une
  # alerte part toujours après le décor ; entre alertes, la moins grave part d'abord.
  item() {
    case $2 in
      2) SEGS+=("${BOLD}${BRED}$1${RST}"); PRIOS+=("${4:-1}") ;;
      1) SEGS+=("${BYELLOW}$1${RST}"); PRIOS+=("${4:-3}") ;;
      *) SEGS+=("${GRAY}$1${RST}"); PRIOS+=("$3") ;;
    esac
    LEVELS+=("$2")
  }

  # Données tenues à jour en arrière-plan : PM2, builds, sessions, disques, plus gros
  # consommateur de mémoire.
  _pt=""; _po=""; _pe=""; _ps=""; _bu=0; _se=0; _dk=""; _gros=""
  if cache_line _sv serveur; then
    IFS='|' read -r _v _e _pt _po _pe _ps _bu _se _dk _gros <<< "$_sv"
    [ "$_v" = v3 ] || { _pt=""; _dk=""; _bu=0; _se=0; _gros=""; }
  fi

  # Processeur : part du temps où les cœurs ont travaillé depuis le relevé précédent (comme
  # htop : tout sauf l'inactivité et l'attente du disque). /proc/stat ne donne que des
  # compteurs depuis le démarrage : le relevé précédent est gardé dans le cache, et la mesure
  # porte sur l'intervalle entre deux relevés espacés d'au moins 2 secondes.
  _c0=""; _cu=""; _cn=""; _cs=""; _ci=""; _cw=0; _cq=0; _csq=0; _cst=0; _cpu=""
  read -r _c0 _cu _cn _cs _ci _cw _cq _csq _cst _ < "$P_PROC/stat" 2>/dev/null
  if [ "$_c0" = cpu ] && is_uint "$_cu" && is_uint "$_cn" && is_uint "$_cs" && is_uint "$_ci" \
     && is_uint "${_cw:=0}" && is_uint "${_cq:=0}" && is_uint "${_csq:=0}" && is_uint "${_cst:=0}"; then
    _ctot=$((_cu + _cn + _cs + _ci + _cw + _cq + _csq + _cst))
    _cidle=$((_ci + _cw))
    _c_v=""; _c_e=""; _c_t=""; _c_i=""; _c_p=""
    if cache_line _cl cpu; then
      IFS='|' read -r _c_v _c_e _c_t _c_i _c_p <<< "$_cl"
      { [ "$_c_v" = v3 ] && is_uint "$_c_e" && is_uint "$_c_t" && is_uint "$_c_i"; } || { _c_e=""; _c_t=""; _c_i=""; _c_p=""; }
    fi
    _frais=0
    if [ -n "$_c_t" ] && [ "$_c_e" -le "$NOW" ] && [ "$_ctot" -gt "$_c_t" ] && [ "$_cidle" -ge "$_c_i" ]; then
      if [ $((NOW - _c_e)) -ge 2 ]; then
        _cpu=$(( ((_ctot - _c_t) - (_cidle - _c_i)) * 100 / (_ctot - _c_t) ))
        [ "$_cpu" -lt 0 ] && _cpu=0
      else
        # Relevé trop récent pour une mesure fiable : on garde la dernière valeur calculée.
        _frais=1
        is_uint "$_c_p" && [ "$_c_p" -le 100 ] && _cpu=$_c_p
      fi
    fi
    if [ "$_frais" = 0 ] && [ -n "$CACHE_DIR" ]; then
      printf 'v3|%s|%s|%s|%s\n' "$NOW" "$_ctot" "$_cidle" "$_cpu" > "$CACHE_DIR/cpu" 2>/dev/null
    fi
  fi
  if [ -n "$_cpu" ]; then
    _lvl=0; [ "$_cpu" -ge 70 ] && _lvl=1; [ "$_cpu" -ge 90 ] && _lvl=2
    item "CPU ${_cpu}%" "$_lvl" 6 3
  fi

  # Mémoire. Quand elle est sous tension, le nom et le poids du plus gros consommateur suivent.
  # (Le swap n'est pas affiché : plein en permanence sur certains serveurs sans que rien
  # n'attende de mémoire, il ne dit rien ; c'est la pression mémoire qui signale le vrai manque.)
  _mt=""; _ma=""
  while IFS=': ' read -r _k _val _; do
    case $_k in
      MemTotal) _mt=$_val ;;
      MemAvailable) _ma=$_val; break ;;
    esac
  done < "$P_PROC/meminfo" 2>/dev/null
  if is_uint "$_mt" && is_uint "$_ma" && [ "$_mt" -gt 0 ]; then
    _ram=$(((_mt - _ma) * 100 / _mt))
    _lvl=0; [ "$_ram" -ge 80 ] && _lvl=1; [ "$_ram" -ge 90 ] && _lvl=2
    _rtxt="RAM ${_ram}%"
    if [ "$_lvl" -ge 1 ] && [[ $_gros =~ ^([A-Za-z0-9._@+-]{1,40})=([0-9]{1,7})$ ]]; then
      _gn=${BASH_REMATCH[1]}; _gm=$((10#${BASH_REMATCH[2]}))
      if [ "$_gm" -ge 1024 ]; then _rtxt+=" · ${_gn} $((_gm / 1024)),$(((_gm % 1024) * 10 / 1024)) Go"
      elif [ "$_gm" -gt 0 ]; then _rtxt+=" · ${_gn} ${_gm} Mo"; fi
    fi
    item "$_rtxt" "$_lvl" 4 2
  fi
  # Pression mémoire (PSI, part du temps où des processus attendent de la mémoire, sur 10 s) :
  # le signe avant-coureur d'un manque de mémoire pendant les builds.
  _psi=""
  read -r _ _psi _ < "$P_PROC/pressure/memory" 2>/dev/null
  _psi=${_psi#avg10=}; _psi=${_psi%.*}
  if is_uint "$_psi" && [ "$_psi" -ge 5 ]; then
    if [ "$_psi" -ge 20 ]; then item "pression mémoire ${_psi}%" 2 0; else item "pression mémoire ${_psi}%" 1 0; fi
  fi

  # Disques : la racine d'abord, puis les autres montages par leur nom court.
  _dtxt=""; _dlvl=0
  for _p in $_dk; do
    _m=${_p%%=*}; _pc=${_p##*=}
    is_uint "$_pc" && [[ $_m == /* ]] || continue
    _n=${_m##*/}; [ "$_m" = "/" ] && _n=""
    [[ $_n =~ ^[A-Za-z0-9._-]{0,20}$ ]] || _n="?"
    if [ -n "$_dtxt" ]; then _dtxt+=" · "; fi
    _dtxt+="${_n:+$_n }${_pc}%"
    [ "$_pc" -ge 80 ] && [ "$_dlvl" -lt 1 ] && _dlvl=1
    [ "$_pc" -ge 90 ] && _dlvl=2
  done
  [ -n "$_dtxt" ] && item "disque ${_dtxt}" "$_dlvl" 5

  if is_uint "$_pt" && is_uint "$_po" && is_uint "$_pe" && is_uint "$_ps" && [ "$_pt" -gt 0 ]; then
    if [ "$_pe" -gt 0 ]; then item "PM2 ${_po}/${_pt} · ${_pe} en erreur" 2 0
    elif [ "$_ps" -gt 0 ]; then item "PM2 ${_po}/${_pt} · ${_ps} à l’arrêt" 1 0; fi
    # Toutes les apps en ligne : rien à dire (l'app où l'on se trouve a son état en ligne 3).
  fi
  if is_uint "$_bu" && [ "$_bu" -gt 0 ]; then
    if [ "$_bu" -gt 1 ]; then item "${_bu} builds en cours" 1 0 3; else item "1 build en cours" 1 0 3; fi
  fi
  # Autres sessions Claude ouvertes sur la machine : quelqu'un d'autre y travaille peut-être.
  if is_uint "$_se" && [ "$_se" -ge 2 ]; then item "${_se} sessions Claude" 1 0 2; fi
  # (Redémarrage demandé et mises à jour en attente ne sont pas affichés : le 13/11, cinq
  # serveurs sur six demandaient un redémarrage et tous avaient des mises à jour en attente.
  # Un signal toujours allumé n'en est plus un.)

  # Si des alertes n'ont pas tenu dans la largeur, la ligne le dit (« +2 alertes », ou « +2 »
  # quand la place manque) : une alerte ne disparaît jamais sans laisser de trace.
  _orig=("${SEGS[@]}"); _np=${#_orig[@]}
  compter_cachees() {
    _cachees=0
    for _i in "${!_orig[@]}"; do
      [ -z "${SEGS[$_i]}" ] && [ "${LEVELS[$_i]:-0}" -ge 1 ] && _cachees=$((_cachees + 1))
    done
  }
  fit LINE0 "$MAXW"; compter_cachees
  if [ "$_cachees" -gt 0 ]; then
    PRIOS[$_np]=0
    for _tour in 1 2 3; do
      _avant=$_cachees
      SEGS=("${_orig[@]}" "${BOLD}${BYELLOW}+${_cachees}${RST}")
      fit LINE0 "$MAXW"; compter_cachees
      [ "$_cachees" -eq "$_avant" ] && break
    done
    _court=$LINE0; _nc=$_cachees
    _mot="alertes"; [ "$_nc" -eq 1 ] && _mot="alerte"
    SEGS=("${_orig[@]}" "${BOLD}${BYELLOW}+${_nc} ${_mot}${RST}")
    fit LINE0 "$MAXW"; compter_cachees
    [ "$_cachees" -eq "$_nc" ] || LINE0=$_court
  fi
}

# ============================================================================
# VOIE RAPIDE : entre deux rendus complets, seule la ligne du serveur est recalculée
# ============================================================================
# Sur un serveur, Claude Code relance ce script toutes les deux secondes (refreshInterval) pour
# que le processeur et la mémoire bougent à l'écran. Refaire tout le rendu à chaque fois
# coûterait un appel à jq, un appel à git et la lecture du fichier entier. Quand rien n'a changé
# dans ce que Claude Code transmet, la voie rapide reprend telles quelles les trois lignes du
# dernier rendu complet (la « trame », gardée dans le cache), ne recalcule que la ligne du
# serveur, et s'arrête ici : la suite du fichier n'est ni lue ni exécutée.
# Elle est abandonnée, au profit d'un rendu complet, dès que : l'entrée a changé (hors durée de
# session), la largeur du terminal a changé, la trame a plus de 15 secondes, un cache
# d'arrière-plan est plus récent qu'elle, ou son contenu n'est pas celui que ce script écrit.
TRAME_TTL=15
INPUT=""

# cle_entree <variable> : l'entrée, sans la durée de session (seul champ qui avance tout seul).
cle_entree() {
  local -n _ke_out=$1
  _ke_out=$INPUT
  if [[ $INPUT =~ ^(.*\"total_duration_ms\"[[:space:]]*:[[:space:]]*)[0-9.]+(.*)$ ]]; then
    _ke_out="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
}

# sgr_seul <ligne> : vrai si la ligne ne porte que des couleurs (ESC [ chiffres m) et aucun autre
# caractère de contrôle. Une trame qui contiendrait autre chose n'est pas réaffichée.
sgr_seul() {
  local LC_ALL=C s=$1 reste=""
  while [[ $s == *$'\033['* ]]; do
    reste+=${s%%$'\033['*}
    s=${s#*$'\033['}
    [[ $s =~ ^[0-9\;]*m ]] || return 1
    s=${s#*m}
  done
  reste+=$s
  [[ $reste != *[$'\001'-$'\037'$'\177']* ]]
}

voie_rapide() {
  local sid f v="" e="" cols="" l1="" l2="" l3="" stock="" cle n
  [[ $INPUT =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{6,64})\" ]] || return 1
  sid=${BASH_REMATCH[1]}
  f="$CACHE_DIR/trame-$sid"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  { IFS='|' read -r v e cols; IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r -d '' stock; } < "$f" 2>/dev/null
  [ "$v" = v3 ] && is_uint "$e" && [ "$e" -le "$NOW" ] && [ $((NOW - e)) -lt "$TRAME_TTL" ] || return 1
  [ "$cols" = "${COLUMNS:-}" ] || return 1
  # Un cache d'arrière-plan rafraîchi depuis la trame (quotas, statut, apps PM2) : rendu complet.
  for n in usage statut pm2-apps; do
    [ "$CACHE_DIR/$n" -nt "$f" ] && return 1
  done
  cle_entree cle
  [ "$cle" = "$stock" ] || return 1
  [ -n "$l1" ] && sgr_seul "$l1" && sgr_seul "$l2" && sgr_seul "$l3" || return 1
  ligne_serveur
  [ -n "$LINE0" ] && printf '%s\n' "$LINE0"
  printf '%s\n' "$l1" "$l2"
  [ -n "$l3" ] && printf '%s\n' "$l3"
  return 0
}

if [ "${1:-}" != "--rafraichir" ]; then
  IFS= read -r -d '' INPUT
  if [ "$SRV_MODE" = 1 ] && [ -n "$CACHE_DIR" ] && voie_rapide; then exit 0; fi
fi

# ============================================================================
# RAFRAÎCHISSEMENT D'ARRIÈRE-PLAN
# ============================================================================
# Tout ce qui est lent ou sort sur le réseau se fait ici, hors du rendu : API des quotas,
# lecture des JSONL pour les coûts, statut de Claude, état PM2 et disques du serveur. Le rendu
# ne lit que des caches : il reste immédiat même quand le réseau ne répond pas, et Claude Code
# n'a plus à l'annuler en route. Lancé par le rendu en processus détaché
# (« statusline.sh --rafraichir … »), un seul à la fois par profil.

LOCK_DIR=""
[ -n "$CACHE_DIR" ] && LOCK_DIR="$CACHE_DIR/verrou.d"

# Vrai si un rafraîchissement vivant tient le verrou (processus présent, verrou de moins de 15 min).
refresh_running() {
  local pid="" ts=""
  [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ] || return 1
  read -r pid ts < "$LOCK_DIR/pid" 2>/dev/null
  is_uint "$pid" && is_uint "$ts" && [ $((NOW - ts)) -lt 900 ] && kill -0 "$pid" 2>/dev/null
}

# mkdir est atomique sur tous les systèmes : un seul rafraîchissement prend le verrou. Un verrou
# dont le processus n'existe plus (rendu tué, machine redémarrée) est repris aussitôt.
lock_acquire() {
  [ -n "$LOCK_DIR" ] || return 1
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    refresh_running && return 1
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  printf '%s %s\n' "$$" "$NOW" > "$LOCK_DIR/pid" 2>/dev/null
  trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  return 0
}

# --- Serveur : PM2, builds, sessions Claude, disques ---
refresh_server() {
  local total="" online="" errored="" stopped="" builds=0 sessions=0 disks="" k a b c d m pct
  local mk mv mt="" ma="" rss="" pid="" nom="" cwd="" gros=""
  local apps_tmp="$CACHE_DIR/.pm2-apps.$$"
  : > "$apps_tmp" 2>/dev/null
  # PM2 : seulement si le démon de CE compte tourne déjà (`pm2 jlist` sans démon en lancerait
  # un). La sortie de jlist porte l'environnement complet de chaque app, secrets compris : elle
  # ne quitte pas le tube, jq n'en garde que le dossier, le nom, l'état et les redémarrages.
  local pm2home="${PM2_HOME:-$_HOME/.pm2}" pm2pid=""
  # (pm2.pid n'a pas de saut de ligne final : `read` rend alors un code d'erreur tout en ayant
  # lu la valeur ; seul le contenu compte.)
  [ -r "$pm2home/pm2.pid" ] && IFS= read -r pm2pid < "$pm2home/pm2.pid" 2>/dev/null
  if command -v pm2 >/dev/null 2>&1 && [ -S "$pm2home/rpc.sock" ] && is_uint "$pm2pid" && kill -0 "$pm2pid" 2>/dev/null; then
    while IFS='|' read -r k a b c d; do
      case $k in
        R) if is_uint "$a" && is_uint "$b" && is_uint "$c" && is_uint "$d"; then total=$a; online=$b; errored=$c; stopped=$d; fi ;;
        A) clean a; clean b
           [[ $c =~ ^[a-z\ -]{1,24}$ ]] || c="?"
           is_uint "$d" || d=0
           [ -n "$a" ] && printf '%s|%s|%s|%s\n' "$a" "$b" "$c" "$d" >> "$apps_tmp" ;;
      esac
    done < <(borne 8 pm2 jlist 2>/dev/null | sed -n '/^\[/,$p' | jq -r '
        (map(.pm2_env.status // "?")) as $s
        | "R|\(length)|\([$s[] | select(. == "online")] | length)|\([$s[] | select(. == "errored")] | length)|\([$s[] | select(. == "stopped" or . == "stopping")] | length)",
          (.[] | "A|\((.pm2_env.pm_cwd // "") | tostring | gsub("[|\\n\\r]"; " "))|\((.name // "") | tostring | gsub("[|\\n\\r]"; " "))|\(.pm2_env.status // "?")|\(.pm2_env.restart_time // 0)")
      ' 2>/dev/null)
  fi
  # Builds Next en cours : ce sont eux qui saturent la mémoire des serveurs de sites.
  # Un build, un processus : le shell ou le gestionnaire de paquets qui enchaîne
  # « … && next build » n'est pas compté (sinon un seul build en vaut deux).
  builds=$(ps -eo args= 2>/dev/null | awk '$1 !~ /^(sh|bash|dash|npm|pnpm|yarn|npx)$/ && /(^|[ \/])next(-| )build( |$)/ {n++} END {print n + 0}')
  is_uint "$builds" || builds=0
  # Sessions Claude interactives ouvertes sur la machine (un terminal chacune), tous comptes
  # confondus quand /proc n'est pas cloisonné : savoir qu'un collègue travaille ici.
  sessions=$(ps -eo tty=,args= 2>/dev/null | awk '$1 ~ /^pts\// && ($2 ~ /(^|\/)claude$/ || $2 ~ /\/claude\/versions\//) { t[$1] = 1 } END { n = 0; for (k in t) n++; print n }')
  is_uint "$sessions" || sessions=0
  for m in $SRV_DISKS; do
    [[ $m == /* ]] || continue
    pct=$(borne 3 df -P -- "$m" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')
    is_uint "$pct" && disks+="${m}=${pct} "
  done
  # Mémoire prise à 80 % ou plus : qui en tient le plus ? Le nom du programme seulement, jamais
  # ses arguments (ils peuvent porter des secrets). Un programme lancé depuis le dossier d'une
  # app prend le nom de l'app : « mon-site.fr » dit plus que « node ».
  while IFS=': ' read -r mk mv _; do
    case $mk in MemTotal) mt=$mv ;; MemAvailable) ma=$mv; break ;; esac
  done < "$P_PROC/meminfo" 2>/dev/null
  if is_uint "$mt" && is_uint "$ma" && [ "$mt" -gt 0 ] && [ $(((mt - ma) * 100 / mt)) -ge 80 ]; then
    read -r rss pid nom < <(ps -eo rss=,pid=,comm= --sort=-rss 2>/dev/null | head -1)
    if is_uint "$rss" && is_uint "$pid"; then
      cwd=$(readlink "$P_PROC/$pid/cwd" 2>/dev/null)
      case $cwd in /var/www/apps/?*) nom=${cwd#/var/www/apps/}; nom=${nom%%/*} ;; esac
      nom=${nom%% *}; nom=${nom//[^A-Za-z0-9._@+-]/}; nom=${nom:0:40}
      [ -n "$nom" ] || nom="?"
      gros="${nom}=$((rss / 1024))"
    fi
  fi
  mv -f "$apps_tmp" "$CACHE_DIR/pm2-apps" 2>/dev/null
  cache_put serveur "v3|$NOW|$total|$online|$errored|$stopped|$builds|$sessions|${disks% }|$gros"
}

# --- Statut de Claude (status.claude.com) ---
refresh_status() {
  local json ind="" prev pv pe pi
  # summary.json inclut incidents, composants et maintenances programmees
  json=$(curl -sf --max-time 3 "https://status.claude.com/api/v2/summary.json" 2>/dev/null) || json=""
  if [ -n "$json" ]; then
    ind=$(printf '%s' "$json" | jq -r '
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
    ' 2>/dev/null) || ind=""
  fi
  case $ind in
    none|minor|major|critical|maintenance) ;;
    *) # Pas de réponse : on garde le dernier état connu, et on ne réessaie qu'au prochain tour.
       ind="inconnu"
       if cache_line prev statut; then
         IFS='|' read -r pv pe pi <<< "$prev"
         case $pi in none|minor|major|critical|maintenance) ind=$pi ;; esac
       fi ;;
  esac
  cache_put statut "v3|$NOW|$ind"
}

# Extraction d'un JSONL : un enregistrement par ligne de reponse (cle reqId nue, la dedup par
# requete se fait a l'agregation : derniere ligne = compteurs definitifs), portant un tableau
# attempts des tentatives facturables. Cas normal : 1 tentative = usage de premier niveau. Cas
# fallback cote serveur (refus Fable / Opus 5.5 / Opus 5 / Sonnet 5.5 -> modele de repli) :
# usage.iterations est le registre officiel de facturation, chaque tentative etant facturee au
# tarif de SON modele et a SA vitesse (un repli peut surcharger speed ; a defaut, speed de la
# requete). Une tentative sans aucun output (refus avant le premier token) n'est pas facturee,
# de meme qu'un refus sec (stop_reason refusal sans output) hors fallback -> attempts vide, ce
# qui neutralise aussi les lignes de streaming intermediaires de la meme requete.
# Lecture ligne par ligne (-R + fromjson?) : une ligne tronquee, celle qu'une session est en
# train d'ecrire, est ignoree au lieu d'arreter la lecture du fichier.
EXTRACT_JQ='
  fromjson? | select(type == "object" and .type == "assistant" and .timestamp != null and .message.model != null) |
  .message.model as $m | (.message.usage.speed // "standard") as $sp |
  (.message.usage.iterations // []) as $its |
  {ts: .timestamp, reqId: (.requestId // ""),
   web_search: (.message.usage.server_tool_use.web_search_requests // 0),
   attempts: (
     if ($its | length) > 1 then
       [ $its[] | select((.output_tokens // 0) > 0) |
         {model: (.model // $m), speed: (.speed // $sp),
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
     end)}'

    # Prix officiels Anthropic (USD / MTok) — verifies le 10/11/2026 sur
    # platform.claude.com/docs/en/about-claude/pricing (Fable 5.2, Fable 5.1, Fable 5, Opus 5.5,
    # Opus 5, Opus 4.8, Sonnet 5.5, Sonnet 5, Haiku 5.5 inclus) et recoupes avec le catalogue
    # embarque dans Claude Code 2.1.322 (pricing_tiers). Regle des caches : write 5 min = x1.25
    # input, write 1h = x2 input, read = x0.1 input, sauf Fable 5.2 / 5.1 et Mythos 5.2 / 5.1
    # (read x0.025) et Opus 5.5 / Sonnet 5.5 (read x0.05). En fast mode, les memes multiplicateurs
    # de cache s'appliquent au tarif input fast. Haiku 5.5 est le seul modele a tarif par palier de
    # longueur de prompt (tout x5 au-dela de 100K tokens de prompt, output compris) : le palier est
    # evalue par tentative, exactement comme le fait Claude Code pour cost.total_cost_usd.
    # Source UNIQUE partagee par les couts 7j et 5h : l'agregation plus bas l'injecte telle
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
          if (.model // "" | test("fable-5-2|mythos-5-2")) then
            # Fable 5.2 / Mythos 5.2 (sortis le 09/11/2026, cible de l alias fable de Claude Code) :
            # standard $8/$40 (20 % sous Fable 5.1), caches write $10 / $16, cache read x0.025
            # ($0.20). Premier Fable a fast mode : $16/$80 (x2), caches $20 / $32 / $0.40 (page de
            # prix et tarifs fast en dur dans le binaire Claude Code 2.1.322 ; non mesure en session
            # reelle, le fast mode se payant en credits d usage). Ecart mesure contre
            # cost.total_cost_usd sur une session reelle standard (4 requetes, $0.8031958) : 0 %.
            # Doit rester AVANT fable|mythos, qui le facturerait au tarif Fable 5 ($10/$50, cache
            # read $1).
            if .speed == "fast" then
              ($in*16 + $out*80 + $c5*20 + $c1*32 + $cr*0.4) / 1000000
            else
              ($in*8 + $out*40 + $c5*10 + $c1*16 + $cr*0.2) / 1000000
            end
          elif (.model // "" | test("fable-5-1|mythos-5-1")) then
            # Fable 5.1 / Mythos 5.1 (sortis le 01/09/2026) : memes $10/$50 et caches write que
            # Fable 5, mais cache read a $0.25 (x0.025, taux reconduit sur Fable 5.2). Pas de fast mode.
            ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*0.25) / 1000000
          elif (.model // "" | test("fable|mythos")) then
            # Fable 5 / Mythos 5 (et tout autre Fable / Mythos non reconnu) : tarif unique $10/$50
            # (pas de fast mode). Caches = multiplicateurs officiels (x1.25 / x2 / x0.1) sur le
            # tarif input. Un futur Fable est a revalider a chaque sortie (5.1 puis 5.2 ont change
            # le cache read, 5.2 le tarif de base et le fast mode).
            ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*1) / 1000000
          elif (.model // "" | test("opus-5-5")) then
            # Opus 5.5 (sorti le 22/09/2026) : standard $4/$20, fast $8/$40 (x2). Caches write aux
            # multiplicateurs officiels (x1.25 / x2) mais cache read a x0.05 au lieu de x0.1 :
            # $0.20 en standard, $0.40 en fast. Doit rester AVANT opus-5, qui le capturerait.
            if .speed == "fast" then
              ($in*8 + $out*40 + $c5*10 + $c1*16 + $cr*0.4) / 1000000
            else
              ($in*4 + $out*20 + $c5*5 + $c1*8 + $cr*0.2) / 1000000
            end
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
          elif (.model // "" | test("opus-4-[01]($|[-@])|opus-4($|[-@]2025)")) then
            # Opus 4 (claude-opus-4-20250514) et Opus 4.1 (claude-opus-4-1-20250805) : tarif legacy
            # $15/$75. Retires le 15/06 et le 05/08/2026, conserves pour les messages historiques.
            # Le separateur @ couvre les IDs Google Cloud (claude-opus-4-1@20250805), la fin de
            # chaine les alias sans date du catalogue Claude Code (claude-opus-4, claude-opus-4-0,
            # claude-opus-4-1), qui tombaient sinon dans la branche opus generique a $5/$25.
            ($in*15 + $out*75 + $c5*18.75 + $c1*30 + $cr*1.5) / 1000000
          elif (.model // "" | test("opus")) then
            # Tout autre Opus (futur opus-4-9, opus-6...) : hypothese au tarif Opus 4.5 a 5 ($5/$25,
            # fast x2 comme Opus 5 / 4.8), a revalider a chaque sortie (un opus-5-x autre que 5.5
            # est capture plus haut par opus-5, fast compris).
            # Les seuls Opus legacy ($15/$75) sont captures explicitement juste au-dessus.
            if .speed == "fast" then
              ($in*10 + $out*50 + $c5*12.5 + $c1*20 + $cr*1) / 1000000
            else
              ($in*5 + $out*25 + $c5*6.25 + $c1*10 + $cr*0.5) / 1000000
            end
          elif (.model // "" | test("haiku-5-5")) then
            # Haiku 5.5 (sorti le 07/10/2026, cible de l alias haiku de Claude Code) : premier modele
            # a tarif par palier de longueur de prompt. Prompt <= 100K tokens : $0.10/$0.50, caches
            # $0.125 / $0.20 / $0.01 (multiplicateurs standards x1.25 / x2 / x0.1). Prompt > 100K :
            # tout x5, output compris : $0.50/$2.50, caches $0.625 / $1 / $0.05. Le prompt = input +
            # cache read + cache write (5 min et 1h), compare STRICTEMENT a 100 000, requete par
            # requete (tentative par tentative), comme Claude Code (longPrompt.abovePromptTokens).
            # Ecart mesure contre cost.total_cost_usd sur deux sessions reelles, une sous et une
            # au-dessus du palier : 0 %. Pas de fast mode, pas de repli de refus. Doit rester AVANT
            # haiku, qui le facturerait au tarif Haiku 4.5.
            if ($in + $cr + $c5 + $c1) > 100000 then
              ($in*0.5 + $out*2.5 + $c5*0.625 + $c1*1 + $cr*0.05) / 1000000
            else
              ($in*0.1 + $out*0.5 + $c5*0.125 + $c1*0.2 + $cr*0.01) / 1000000
            end
          elif (.model // "" | test("haiku")) then
            # Haiku 4.5 (et tout autre Haiku non reconnu) : $1/$5. Haiku 3.5 ($0.80/$4) et Haiku 3 sont
            # retires depuis fevrier / avril 2026. Haiku 5.5 est capture juste au-dessus.
            ($in*1 + $out*5 + $c5*1.25 + $c1*2 + $cr*0.1) / 1000000
          elif (.model // "" | test("sonnet-5-5")) then
            # Sonnet 5.5 (sorti le 28/09/2026, alias sonnet de Claude Code) : $2/$10 et caches write
            # $2.50 / $4 comme Sonnet 5, mais cache read a x0.05 ($0.10) au lieu de x0.1 ($0.20).
            # Baisse annoncee par Anthropic le 07/10/2026 (notes de version de la plateforme : read
            # de $0.20 a $0.10), integree ici le 10/11/2026 (palier tier_2_10_cache_read_0_10 du
            # catalogue Claude Code). Ecart mesure contre cost.total_cost_usd sur une session reelle
            # (4 requetes, $0.1546946) : 0 %, contre +8,6 % au tarif Sonnet 5. Pas de fast mode.
            # Doit rester AVANT sonnet-5, qui le capturerait.
            ($in*2 + $out*10 + $c5*2.5 + $c1*4 + $cr*0.1) / 1000000
          elif (.model // "" | test("sonnet-5")) then
            # Sonnet 5 (et tout futur sonnet-5-x non reconnu) : $2/$10. Le tarif de lancement
            # (annonce jusqu au 31/08/2026) est devenu le tarif standard, la hausse a $3/$15 prevue
            # le 01/09/2026 est annulee. Sonnet 5.5 est capture juste au-dessus.
            # Pas de fast mode. Caches = multiplicateurs officiels (x1.25 / x2 / x0.1).
            ($in*2 + $out*10 + $c5*2.5 + $c1*4 + $cr*0.2) / 1000000
          else
            # Fallback general : Sonnet 4.6 / 4.5 et tout ID non reconnu, $3/$15.
            ($in*3 + $out*15 + $c5*3.75 + $c1*6 + $cr*0.3) / 1000000
          end
        ) | add // 0
    '

# --- Quotas (API OAuth) et coûts (JSONL locaux) ---
# $1 = version de Claude Code, $2 / $3 = fin des fenêtres 5 h et 7 j reçues de Claude Code
# (secondes, vides si absentes), $4 = jeton reçu par l'entrée standard (celui de l'environnement).
refresh_usage() {
  local version=$1 rl5=$2 rl7=$3 token=$4
  local prev pv pe pp5="" pr5="" pp7="" pr7="" ppf="" pw="" pb=""
  local p5="" r5="" p7="" r7="" pf="" wcost="" bcost="" x api_http=0 api_ok=0
  if cache_line prev usage; then
    IFS='|' read -r pv pe pp5 pr5 pp7 pr7 ppf pw pb <<< "$prev"
    [ "$pv" = v3 ] || { pp5=""; pr5=""; pp7=""; pr7=""; ppf=""; pw=""; pb=""; }
  fi

  if [ "$OPT_QUOTA_API" = 1 ] && is_stale usage-pause "$USAGE_BACKOFF_TTL"; then
    # Jeton : celui de la session s'il a été transmis (c'est LUI qui sert à la session,
    # pas celui du fichier), sinon .credentials.json du profil (Linux/WSL), sinon le
    # Trousseau (macOS), dans une entrée propre à chaque profil : jamais de repli sur celle du
    # profil par défaut pour un autre compte.
    if [ -z "$token" ] && [ -f "$CLAUDE_DIR/.credentials.json" ]; then
      token=$(jq -r '.claudeAiOauth.accessToken // ""' "$CLAUDE_DIR/.credentials.json" 2>/dev/null) || token=""
    fi
    if [ -z "$token" ] && [ "$(uname)" = "Darwin" ]; then
      # Suffixe du profil : sha256 du chemin CLAUDE_CONFIG_DIR sur 8 caracteres, vide pour le
      # profil par defaut. C'est le suffixe que Claude Code donne a l'entree Trousseau du profil.
      local suffix="" hash="" kc=""
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        if command -v sha256sum >/dev/null 2>&1; then hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | sha256sum)
        else hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256); fi
        suffix="-${hash:0:8}"
      fi
      kc=$(security find-generic-password -s "Claude Code-credentials${suffix}" -a "${USER:-$(id -un)}" -w 2>/dev/null) || kc=""
      [ -n "$kc" ] && token=$(printf '%s' "$kc" | jq -r '.claudeAiOauth.accessToken // ""' 2>/dev/null)
      kc=""
    fi
    # Un jeton ne contient ni guillemet ni saut de ligne : sinon il ne part pas. (Longueur testée
    # à part : la bibliothèque de macOS refuse un intervalle de plus de 255 dans une expression.)
    if ! [[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || [ "${#token}" -lt 20 ] || [ "${#token}" -gt 4096 ]; then token=""; fi
    [[ $version =~ ^[0-9A-Za-z.+-]{1,32}$ ]] || version="0"
    if [ -n "$token" ]; then
      local body="$CACHE_DIR/.api.$$"
      # Le jeton est donné à curl par son entrée standard (-K -), pas en argument : la ligne de
      # commande d'un processus se lit par tous les comptes de la machine (ps, /proc/<pid>/cmdline).
      # printf est une commande interne de bash : elle n'apparaît dans aucune liste de processus.
      api_http=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s --max-time 5 -o "$body" -w '%{http_code}' -K - \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${version}" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || api_http=0
      token=""
      # Sur 429 : attendre 10 min avant de réessayer.
      [ "$api_http" = "429" ] && cache_put usage-pause "v3|$NOW"
      # Valider que la reponse est bien le JSON de /api/oauth/usage : un objet portant au
      # moins une des cles five_hour / seven_day / limits. Ne PAS exiger un five_hour non
      # null : depuis le 31/10/2026 l'API renvoie "five_hour": null sur Max 20x quand le
      # compte n'a pas de fenetre 5h en cours. Les dates sont converties en secondes ici.
      if [ "$api_http" = "200" ]; then
        x=$(jq -r '
          def epoch: if . == null or . == "" then ""
                     elif type == "number" then (floor | tostring)
                     else (tostring | sub("\\.[0-9]+"; "") | sub("(\\+00:00|\\+0000)$"; "Z") | (try (fromdateiso8601 | tostring) catch "")) end;
          if type == "object" and (has("five_hour") or has("seven_day") or has("limits")) then
            [
              # Quota 5h : chaine vide si l API ne rapporte pas de fenetre 5h (segment masque)
              (.five_hour.utilization // "" | tostring),
              (.five_hour.resets_at | epoch),
              # Quota 7j : seven_day, sinon l entree weekly_all du tableau limits
              (.seven_day.utilization // ([.limits[]? | select(.kind == "weekly_all")] | first | .percent) // 0 | tostring),
              ((.seven_day.resets_at // ([.limits[]? | select(.kind == "weekly_all")] | first | .resets_at)) | epoch),
              # Quota 7j dedie a Fable : entree weekly_scoped du tableau limits dont
              # le scope model vise Fable. Chaine vide si absente (segment masque).
              ([.limits[]? | select(.kind == "weekly_scoped" and ((.scope.model.display_name // "") | test("fable"; "i")))] | first | .percent // "" | tostring)
            ] | join("|")
          else empty end
        ' "$body" 2>/dev/null) || x=""
        if [ -n "$x" ]; then
          api_ok=1
          IFS='|' read -r p5 r5 p7 r7 pf <<< "$x"
        fi
      fi
      rm -f "$body" 2>/dev/null
    fi
  fi

  if [ "$api_ok" != 1 ]; then
    # API en échec ou non interrogée : dernières valeurs connues.
    p5=$pp5; r5=$pr5; p7=$pp7; r7=$pr7; pf=$ppf
    # Les fins de fenêtre reçues de Claude Code sont plus fraîches que le cache.
    is_uint "$rl5" && r5=$rl5
    is_uint "$rl7" && r7=$rl7
  fi
  is_num "$p5" || p5=""
  is_num "$p7" || p7=""
  is_num "$pf" || pf=""
  is_uint "$r5" || r5=""
  is_uint "$r7" || r7=""
  # Fenetre 5h deja echue (resets_at passe) : Claude Code la traite comme absente, on fait pareil.
  if [ -n "$r5" ] && [ "$r5" -le "$NOW" ]; then p5=""; r5=""; fi
  [ -n "$r5" ] || p5=""

  # --- Couts 7j et 5h : calcul independant (JSONL locaux, pas l'API) ---
  if [ "$OPT_COSTS" = 1 ] && [ -n "$r7" ] && [ -d "$CLAUDE_DIR/projects/" ]; then
    local ws bs ex_dir="$CACHE_DIR/extraits" ref="$CACHE_DIR/.ref.$$" f ex
    # Début de la semaine : fin de fenêtre moins 7 jours. Si la fin connue est passée (API
    # muette depuis), la fenêtre suivante a commencé à cette date : on avance par pas de 7 jours.
    if [ "$r7" -gt "$NOW" ]; then ws=$((r7 - 604800)); else ws=$((r7 + ((NOW - r7) / 604800) * 604800)); fi
    # Sans fenêtre 5 h rapportée : fenêtre glissante de 5 h depuis maintenant.
    if [ -n "$r5" ]; then bs=$((r5 - 18000)); else bs=$((NOW - 18000)); fi
    # Un extrait par JSONL, refait seulement quand le JSONL a changé : après le premier passage,
    # seules les sessions en cours sont relues (la base relisait toute la semaine à chaque fois :
    # 14 s mesurées sur un serveur portant 1,5 Go de transcriptions). L'extrait prend la date du
    # DÉBUT du passage : une écriture arrivée pendant la lecture le fera relire au suivant.
    mkdir -p "$ex_dir" 2>/dev/null
    : > "$ref" 2>/dev/null
    while IFS= read -r -d '' f; do
      ex="$ex_dir/${f#"$CLAUDE_DIR/projects/"}.x"
      if [ ! -e "$ex" ] || [ "$f" -nt "$ex" ]; then
        [ -d "${ex%/*}" ] || mkdir -p "${ex%/*}" 2>/dev/null
        grep -F '"type":"assistant"' "$f" 2>/dev/null | jq -cR "$EXTRACT_JQ" > "$ex.tmp" 2>/dev/null
        mv -f "$ex.tmp" "$ex" 2>/dev/null && touch -r "$ref" "$ex" 2>/dev/null
      fi
    done < <(find "$CLAUDE_DIR/projects/" -name '*.jsonl' -mtime -7 -print0 2>/dev/null)
    rm -f "$ref" 2>/dev/null
    # Les bornes sont converties en dates ISO par jq (todate), donc en UTC quel que soit le
    # fuseau de la machine, pour être comparées aux horodatages des JSONL.
    x=$(find "$ex_dir" -name '*.x' -exec cat {} + 2>/dev/null | jq -rs --argjson ws "$ws" --argjson bs "$bs" \
      'def cout: '"$COST_MAP_JQ"'; ($ws | todate) as $tw | ($bs | todate) as $tb
       | ([.[] | select(.ts > $tw)]) as $w | "\($w | cout)|\([$w[] | select(.ts > $tb)] | cout)"' 2>/dev/null) || x=""
    IFS='|' read -r wcost bcost <<< "$x"
    # Extraits des transcriptions sorties de la fenêtre, caches git des sessions terminées.
    find "$ex_dir" -name '*.x' -mtime +8 -delete 2>/dev/null
    find "$ex_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
  fi
  # Calcul impossible (jq en échec, fenêtre inconnue) : garder les coûts précédents.
  is_num "$wcost" || wcost=$pw
  is_num "$bcost" || bcost=$pb
  is_num "$wcost" || wcost=0
  is_num "$bcost" || bcost=0
  cache_put usage "v3|$NOW|$p5|$r5|$p7|$r7|$pf|$wcost|$bcost"
}

rafraichir() {
  [ -n "$CACHE_DIR" ] || return 0
  local token_env=""
  # Jeton reçu de l'environnement, s'il y en a un : une ligne sur l'entrée standard, rien sinon.
  IFS= read -r -t 2 token_env || true
  lock_acquire || return 0
  # Caches des sessions terminées (git, trame) : plus de deux jours.
  find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'git-*' -o -name 'trame-*' \) -mtime +2 -delete 2>/dev/null
  # Fichiers de travail laissés par un rafraîchissement interrompu (plus de 10 minutes).
  find "$CACHE_DIR" -maxdepth 1 -type f -name '.*.[0-9]*' -mmin +10 -delete 2>/dev/null
  # Priorité la plus basse : la lecture des JSONL ne doit rien prendre aux sites.
  command -v renice >/dev/null 2>&1 && renice -n 19 "$$" >/dev/null 2>&1
  if [ "$SRV_MODE" = 1 ] && is_stale serveur "$SERVER_TTL"; then refresh_server; fi
  if [ "$OPT_STATUS" = 1 ] && is_stale statut "$STATUS_TTL"; then refresh_status; fi
  if { [ "$OPT_QUOTA_API" = 1 ] || [ "$OPT_COSTS" = 1 ]; } && is_stale usage "$USAGE_TTL"; then
    refresh_usage "${1:-}" "${2:-}" "${3:-}" "$token_env"
  fi
  token_env=""
  return 0
}

if [ "${1:-}" = "--rafraichir" ]; then
  rafraichir "${2:-}" "${3:-}" "${4:-}"
  exit 0
fi

# ============================================================================
# RENDU
# ============================================================================

# --- Lecture de l'entrée : un seul appel jq, un champ par ligne ---
# Rien n'est évalué (plus de « eval ») : chaque champ est ramené à une ligne de texte bornée,
# lu tel quel, puis validé selon son type. Le dernier champ, « FIN », prouve que les lignes
# sont bien alignées ; sinon tout retombe sur les valeurs par défaut.
# fast_mode : test explicite de null, car l'operateur // de jq traite false comme absent.
JQ_FIELDS='
  def s(n): (if . == null then "" else . end) | tostring | gsub("[\\n\\r\\t]"; " ") | .[0:n];
  [
    (.model.display_name | s(40)),
    ((.workspace.current_dir // .cwd // ".") | s(1024)),
    (.version | s(32)),
    ((.cost.total_cost_usd // 0) | s(24)),
    ((.cost.total_duration_ms // 0) | s(24)),
    ((.context_window.used_percentage // 0) | s(24)),
    (.agent.name | s(40)),
    (.vim.mode | s(16)),
    (.transcript_path | s(1024)),
    (.effort.level | s(16)),
    (.fast_mode | s(8)),
    (.rate_limits.five_hour.used_percentage | s(24)),
    (.rate_limits.five_hour.resets_at | s(24)),
    (.rate_limits.seven_day.used_percentage | s(24)),
    (.rate_limits.seven_day.resets_at | s(24)),
    (.session_id | s(64)),
    (.session_name | s(60)),
    "FIN"
  ] | .[]'
F=()
# (L'entrée est donnée à jq par un tube : avec « <<< », bash écrit un fichier provisoire dans
# /tmp dès que le texte dépasse la taille d'un tube.)
mapfile -t F < <(printf '%s' "$INPUT" | jq -r "$JQ_FIELDS" 2>/dev/null)
[ "${F[17]:-}" = "FIN" ] || F=()

MODEL_NAME=${F[0]:-}; DIR=${F[1]:-}; VERSION=${F[2]:-}; COST=${F[3]:-}; DURATION_MS=${F[4]:-}
CTX_PCT=${F[5]:-}; AGENT_NAME=${F[6]:-}; VIM_MODE=${F[7]:-}; TRANSCRIPT_PATH=${F[8]:-}
EFFORT_STDIN=${F[9]:-}; FAST_STDIN=${F[10]:-}; RL5_PCT=${F[11]:-}; RL5_RESET=${F[12]:-}
RL7_PCT=${F[13]:-}; RL7_RESET=${F[14]:-}; SESSION_ID=${F[15]:-}; SESSION_NAME=${F[16]:-}

for _v in MODEL_NAME DIR VERSION AGENT_NAME VIM_MODE TRANSCRIPT_PATH EFFORT_STDIN SESSION_NAME; do clean "$_v"; done
[ -n "$MODEL_NAME" ] || MODEL_NAME="---"
[[ $VERSION =~ ^[0-9A-Za-z.+-]{1,32}$ ]] || VERSION="---"
[[ $DIR == /* ]] || DIR="."
# Un chemin de transcription est absolu ; sinon il n'est pas lu (il finirait en option de grep).
[[ $TRANSCRIPT_PATH == /* ]] || TRANSCRIPT_PATH=""
is_num "$COST" || COST=0
DURATION_MS=${DURATION_MS%.*}; is_uint "$DURATION_MS" || DURATION_MS=0
[[ $EFFORT_STDIN =~ ^[a-z]{1,12}$ ]] || EFFORT_STDIN=""
case $FAST_STDIN in true|false) ;; *) FAST_STDIN="" ;; esac
is_num "$RL5_PCT" || RL5_PCT=""
is_num "$RL7_PCT" || RL7_PCT=""
RL5_RESET=${RL5_RESET%.*}; is_uint "$RL5_RESET" || RL5_RESET=""
RL7_RESET=${RL7_RESET%.*}; is_uint "$RL7_RESET" || RL7_RESET=""
[[ $SESSION_ID =~ ^[A-Za-z0-9_-]{6,64}$ ]] || SESSION_ID="defaut"

# --- Nom du projet ---
PROJECT="${DIR##*/}"
[ -n "$PROJECT" ] || PROJECT="/"
if [ "$SRV_MODE" = 1 ] && [[ $DIR == /* ]]; then
  # Sur un serveur, le dossier parent compte autant que le dossier : « …/apps/site.fr ».
  _d=$DIR
  if [ -n "$_HOME" ] && [ "$_d" = "$_HOME" ]; then _d="~"
  elif [ -n "$_HOME" ] && [[ $_d == "$_HOME"/* ]]; then _d="~${_d#"$_HOME"}"; fi
  _tail=${_d##*/}; _head=${_d%/*}; _mid=${_head##*/}
  if [ "$_head" = "$_d" ] || [ -z "$_head" ] || [ "$_head" = "~" ] || [ "$_head" = "/$_mid" ]; then PROJECT=$_d
  else PROJECT="…/$_mid/$_tail"; fi
fi
trunc PROJECT 44

# --- Pourcentage contexte (entier) ---
round_to CTX_PCT_INT "$CTX_PCT" 0

# --- Couleur du modele ---
case "$MODEL_NAME" in
  *Fable*|*fable*|*Mythos*|*mythos*) MC="$GOLD" ;;
  *Opus*|*opus*)     MC="$MAGENTA" ;;
  *Sonnet*|*sonnet*) MC="$BLUE" ;;
  *Haiku*|*haiku*)   MC="$CYAN" ;;
  *)                 MC="$WHITE" ;;
esac

# ============================================================================
# GIT : un seul appel, en lecture seule, cache de 5 secondes par session
# ============================================================================
# `git status --porcelain=v2 --branch` donne en une fois la branche, l'avance et le retard sur
# l'amont et l'état des fichiers (six appels auparavant). --no-optional-locks : n'écrit jamais
# l'index. -c core.fsmonitor=false : un dépôt peut déclarer dans sa configuration une commande
# à lancer à chaque `status` ; elle n'est pas exécutée ici.
GIT_AVAILABLE=false; GIT_BRANCH=""; GIT_UPSTREAM=0; GIT_FETCHED=0
GIT_STAGED=0; GIT_MODIFIED=0; GIT_UNTRACKED=0; GIT_AHEAD=0; GIT_BEHIND=0
_GIT_CACHE="git-$SESSION_ID"
_git_fresh=0
if [ -n "$CACHE_DIR" ] && [ -f "$CACHE_DIR/$_GIT_CACHE" ] && [ ! -L "$CACHE_DIR/$_GIT_CACHE" ]; then
  _gv=""; _ge=""; _ga=""; _gs=""; _gm=""; _gu=""; _gah=""; _gbe=""; _gup=""; _gfe=""; _gd=""; _gb=""
  { IFS='|' read -r _gv _ge _ga _gs _gm _gu _gah _gbe _gup _gfe; IFS= read -r _gd; IFS= read -r _gb; } < "$CACHE_DIR/$_GIT_CACHE" 2>/dev/null
  if [ "$_gv" = v3 ] && [ "$_gd" = "$DIR" ] && is_uint "$_ge" && is_uint "$_gs" && is_uint "$_gm" && is_uint "$_gu" \
     && is_uint "$_gah" && is_uint "$_gbe" && is_uint "$_gfe"; then
    GIT_FETCHED=$_gfe
    if [ "$_ge" -le "$NOW" ] && [ $((NOW - _ge)) -le "$GIT_TTL" ]; then
      _git_fresh=1
      [ "$_ga" = true ] && GIT_AVAILABLE=true
      [ "$_gup" = 1 ] && GIT_UPSTREAM=1
      GIT_STAGED=$_gs; GIT_MODIFIED=$_gm; GIT_UNTRACKED=$_gu; GIT_AHEAD=$_gah; GIT_BEHIND=$_gbe
      GIT_BRANCH=$_gb; clean GIT_BRANCH
    fi
  fi
fi

if [ "$_git_fresh" = 0 ]; then
  if _gout=$(borne 2 git -C "$DIR" -c core.fsmonitor=false --no-optional-locks status --porcelain=v2 --branch --untracked-files=all 2>/dev/null); then
    GIT_AVAILABLE=true
    while IFS= read -r _l; do
      case $_l in
        '# branch.head '*) GIT_BRANCH=${_l#'# branch.head '} ;;
        '# branch.upstream '*) GIT_UPSTREAM=1 ;;
        '# branch.ab '*)
          _ab=${_l#'# branch.ab '}; _a=${_ab%% *}; _b=${_ab##* }; _a=${_a#+}; _b=${_b#-}
          is_uint "$_a" && GIT_AHEAD=$_a
          is_uint "$_b" && GIT_BEHIND=$_b ;;
        '1 '*|'2 '*)
          [ "${_l:2:1}" != "." ] && GIT_STAGED=$((GIT_STAGED + 1))
          [ "${_l:3:1}" != "." ] && GIT_MODIFIED=$((GIT_MODIFIED + 1)) ;;
        'u '*) GIT_MODIFIED=$((GIT_MODIFIED + 1)) ;;
        '? '*) GIT_UNTRACKED=$((GIT_UNTRACKED + 1)) ;;
      esac
    done < <(printf '%s\n' "$_gout")
    [ "$GIT_BRANCH" = "(detached)" ] && GIT_BRANCH="HEAD"
    clean GIT_BRANCH
    trunc GIT_BRANCH 48
  fi

  # --- Auto-fetch en arrière-plan (postes seulement, jamais en mode serveur) ---
  # Plus de 5 min depuis le dernier fetch ET amont suivi : « git fetch » détaché, les trois
  # descripteurs fermés. La base laissait la sortie standard ouverte au fetch : Claude Code
  # attendait sa fin avant d'afficher la barre.
  if [ "$OPT_AUTOFETCH" = 1 ] && [ "$GIT_AVAILABLE" = true ] && [ "$GIT_UPSTREAM" = 1 ] \
     && { [ "$GIT_FETCHED" -gt "$NOW" ] || [ $((NOW - GIT_FETCHED)) -gt "$FETCH_TTL" ]; }; then
    GIT_FETCHED=$NOW
    ( umask "$_UMASK_SESSION"; GIT_TERMINAL_PROMPT=0 git -C "$DIR" -c core.fsmonitor=false --no-optional-locks fetch --quiet --no-tags </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi

  if [ -n "$CACHE_DIR" ]; then
    printf 'v3|%s|%s|%s|%s|%s|%s|%s|%s|%s\n%s\n%s\n' "$NOW" "$GIT_AVAILABLE" "$GIT_STAGED" "$GIT_MODIFIED" "$GIT_UNTRACKED" \
      "$GIT_AHEAD" "$GIT_BEHIND" "$GIT_UPSTREAM" "$GIT_FETCHED" "$DIR" "$GIT_BRANCH" > "$CACHE_DIR/$_GIT_CACHE" 2>/dev/null
  fi
fi

# --- Segment git ---
GIT_SEGMENT=""
if [ "$GIT_AVAILABLE" = "true" ] && [ -n "$GIT_BRANCH" ]; then
  GIT_SEGMENT="${BCYAN}* ${GIT_BRANCH}${RST}"
  [ "$GIT_STAGED" -gt 0 ] && GIT_SEGMENT+=" ${BGREEN}+${GIT_STAGED}${RST}"
  [ "$GIT_MODIFIED" -gt 0 ] && GIT_SEGMENT+=" ${BYELLOW}~${GIT_MODIFIED}${RST}"
  [ "$GIT_UNTRACKED" -gt 0 ] && GIT_SEGMENT+=" ${RED}?${GIT_UNTRACKED}${RST}"
  [ "$GIT_AHEAD" -gt 0 ] && GIT_SEGMENT+=" ${CYAN}↑${GIT_AHEAD}${RST}"
  [ "$GIT_BEHIND" -gt 0 ] && GIT_SEGMENT+=" ${BYELLOW}↓${GIT_BEHIND}${RST}"
fi

# ============================================================================
# LIGNE 1 : Modele | Fast | Effort | Agent | Vim | Projet | Version | Status
# ============================================================================
L1_HEAD="${BOLD}${MC}${MODEL_NAME}${RST}"
L1_CORE=""   # modèle, fast et effort seuls : ce qui reste de l'en-tête quand la place manque

# Indicateurs Fast mode + Effort level
# Fast mode — source canonique : .fast_mode du JSON stdin, valeur LIVE de la session
# (false sur un modele sans fast mode meme si /fast est memorise : seuls Fable 5.2 /
# Mythos 5.2, Opus 5.5, Opus 5 et Opus 4.8 l'ont ; sur Fable 5.2 il ne s'active que par
# un /fast lance sur ce modele). Fallback settings.json si Claude Code est trop ancien
# pour exposer ce champ.
if [ -n "$FAST_STDIN" ]; then
  FAST_MODE="$FAST_STDIN"
else
  FAST_MODE=$(jq -r '.fastMode // false' "$CLAUDE_DIR/settings.json" 2>/dev/null) || FAST_MODE="false"
fi

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
  EFFORT_LEVEL=$(jq -r '.effortLevel // "default"' "$CLAUDE_DIR/settings.json" 2>/dev/null) || EFFORT_LEVEL="default"
  # Claude Code ecrit deux formats dans local-command-stdout selon que le niveau
  # est persistant ou session-only :
  #   - low/medium/high/xhigh : "Set effort level to <X>: <description>"
  #   - max                   : "Set effort level to max (this session only): ..."
  # Lookahead 200 chars : tolere le suffixe variable, anti-faux-positif.
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    _LIVE_EFFORT=$(grep -oP 'local-command-stdout>Set effort level to \K\w+(?=[^<>]{0,200}</local-command-stdout>)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || _LIVE_EFFORT=""
    [ -z "$_LIVE_EFFORT" ] && _LIVE_EFFORT=$(grep -ioP 'local-command-stdout>(?:current )?effort level: \K\w+(?=[^<>]{0,50}</local-command-stdout>)' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)
    [ -n "$_LIVE_EFFORT" ] && EFFORT_LEVEL="$_LIVE_EFFORT"
  fi
  # Env var CLAUDE_CODE_EFFORT_LEVEL : override absolu cote Claude Code.
  if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
    EFFORT_LEVEL="$CLAUDE_CODE_EFFORT_LEVEL"
  fi
fi
if [ "$FAST_MODE" = "true" ]; then
  L1_HEAD+=" ${BYELLOW}⚡${RST}"
fi

# Barres verticales style signal pour l'effort level
# Haiku 4.5 et anterieurs : aucune barre (pas de niveau d'effort) | Fable / Mythos (5, 5.1 et
# 5.2) + Opus (toutes versions) + Sonnet 5 / 5.5 + Haiku 5.5 : echelle 5 niveaux (xhigh dispo des
# Opus 4.7, sur Fable / Mythos, sur Sonnet 5 / 5.5 et sur Haiku 5.5) | Sonnet 4.6 & autres :
# 4 niveaux. On matche tous les Opus plutot qu'une version precise : future-proof (4.8, 4.9...)
# et sans piege de comparaison de version (4.10 < 4.7 en flottant). Les Opus < 4.7 n'emettent
# jamais xhigh, donc la 4e graduation reste inutilisee pour eux. Sonnet 5 est le premier Sonnet
# a supporter xhigh (5 niveaux) ; le motif "Sonnet 5" capture aussi "Sonnet 5.5" (display_name
# de claude-sonnet-5-5). Haiku 5.5 (display_name "Haiku 5.5", sorti le 07/10/2026) est le
# premier Haiku a effort (low a max, xhigh compris, defaut medium) : son motif "Haiku 5" est
# teste dans la branche 5 niveaux, AVANT le motif Haiku generique qui masque les barres.
B="▌"  # ▌ left half block
OFF="${DIM}${GRAY}"
case "$MODEL_NAME" in
  *Fable*|*fable*|*Mythos*|*mythos*|*Opus*|*opus*|*"Sonnet 5"*|*"sonnet 5"*|*"Haiku 5"*|*"haiku 5"*)
    # 5 niveaux : low, medium, high, xhigh, max
    case "$EFFORT_LEVEL" in
      low)     L1_HEAD+=" ${CYAN}${B}${OFF}${B}${B}${B}${B}${RST}" ;;
      high)    L1_HEAD+=" ${BRED}${B}${B}${B}${OFF}${B}${B}${RST}" ;;
      xhigh)   L1_HEAD+=" ${ORANGE}${B}${B}${B}${B}${OFF}${B}${RST}" ;;
      max)     L1_HEAD+=" ${MAGENTA}${B}${B}${B}${B}${B}${RST}" ;;
      ultra|ultracode) L1_HEAD+=" ${UMAGENTA}${B}${B}${B}${B}${B}${RST} ${UMAGENTA}✦${RST}" ;;
      *)       L1_HEAD+=" ${BYELLOW}${B}${B}${OFF}${B}${B}${B}${RST}" ;;
    esac
    ;;
  *Haiku*|*haiku*)
    : # pas d'indicateur d'effort sur Haiku 4.5 et anterieurs (Haiku 5.5 est capture au-dessus)
    ;;
  *)
    # 4 niveaux : low, medium, high, max (xhigh fallback sur high)
    case "$EFFORT_LEVEL" in
      low)         L1_HEAD+=" ${CYAN}${B}${OFF}${B}${B}${B}${RST}" ;;
      high|xhigh)  L1_HEAD+=" ${BRED}${B}${B}${B}${OFF}${B}${RST}" ;;
      max)         L1_HEAD+=" ${MAGENTA}${B}${B}${B}${B}${RST}" ;;
      ultra|ultracode) L1_HEAD+=" ${UMAGENTA}${B}${B}${B}${B}${RST} ${UMAGENTA}✦${RST}" ;;
      *)           L1_HEAD+=" ${BYELLOW}${B}${B}${OFF}${B}${B}${RST}" ;;
    esac
    ;;
esac

L1_CORE=$L1_HEAD

# Agent (si present)
if [ -n "$AGENT_NAME" ]; then L1_HEAD+=" ${DIM}${GRAY}@${AGENT_NAME}${RST}"; fi

# Vim mode (si present)
case "$VIM_MODE" in
  NORMAL) L1_HEAD+=" ${GREEN}[N]${RST}" ;;
  INSERT) L1_HEAD+=" ${YELLOW}[I]${RST}" ;;
esac

# Status Claude (status.claude.com — cache 60s, rafraîchi en arrière-plan)
STATUS_IND="inconnu"
if [ "$OPT_STATUS" = 1 ] && cache_line _st statut; then
  IFS='|' read -r _sv _se _si <<< "$_st"
  [ "$_sv" = v3 ] && STATUS_IND=$_si
fi
DOT="●"
case "$STATUS_IND" in
  none)        STATUS_DOT=" ${BGREEN}${DOT}${RST}" ;;
  minor)       STATUS_DOT=" ${BYELLOW}${DOT}${RST}" ;;
  major)       STATUS_DOT=" ${ORANGE}${DOT}${RST}" ;;
  critical)    STATUS_DOT=" ${BRED}${DOT}${RST}" ;;
  maintenance) STATUS_DOT=" ${BLUE}${DOT}${RST}" ;;
  *)           # état pas encore connu (premier rendu, réseau muet) : point gris, pas un faux vert
               if [ "$OPT_STATUS" = 1 ]; then STATUS_DOT=" ${DIM}${GRAY}${DOT}${RST}"; else STATUS_DOT=""; fi ;;
esac

SEGS=(); PRIOS=()
SEGS+=("$L1_HEAD");                                   PRIOS+=(0)
SEGS+=("${WHITE}${BOLD}${PROJECT}${RST}");            PRIOS+=(2)
if [ "$SRV_MODE" = 1 ] && [ -n "$SESSION_NAME" ]; then
  trunc SESSION_NAME 30
  SEGS+=("${DIM}${GRAY}${SESSION_NAME}${RST}");       PRIOS+=(5)
fi
SEGS+=("${DIM}${GRAY}v${VERSION}${RST}${STATUS_DOT}"); PRIOS+=(3)
fit LINE1 "$MAXW"
vlen _w "$LINE1"
if [ "$_w" -gt "$MAXW" ]; then SEGS[0]=$L1_CORE; fit LINE1 "$MAXW"; fi

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
  PCT_LABEL="${BOLD}${BRED}${CTX_PCT_INT}%${RST}"
elif [ "$CTX_PCT_INT" -ge 70 ]; then
  BAR_COLOR="$BYELLOW"
  PCT_LABEL="${BOLD}${BYELLOW}${CTX_PCT_INT}%${RST}"
else
  BAR_COLOR="$BGREEN"
  PCT_LABEL="${BGREEN}${CTX_PCT_INT}%${RST}"
fi

# rep <variable> <caractère> <nombre> : répète un caractère sans boucle ni sous-processus.
rep() {
  local -n _rp_out=$1
  _rp_out=""
  [ "$3" -gt 0 ] || return 0
  printf -v _rp_out '%*s' "$3" ""
  _rp_out=${_rp_out// /$2}
}
rep BAR_FILLED "█" "$FILLED"
rep BAR_EMPTY "░" "$EMPTY"
BAR_SEGMENT="${BAR_COLOR}${BAR_FILLED}${DIM}${GRAY}${BAR_EMPTY}${RST} ${PCT_LABEL}"
# barre_contexte <variable> <largeur> : la même barre, à la largeur demandée.
barre_contexte() {
  local -n _bc_out=$1
  local w=$2 f e bf be
  f=$((CTX_PCT_INT * w / 100)); [ "$f" -gt "$w" ] && f=$w
  e=$((w - f))
  rep bf "█" "$f"
  rep be "░" "$e"
  _bc_out="${BAR_COLOR}${bf}${DIM}${GRAY}${be}${RST} ${PCT_LABEL}"
}

# --- Session : cout ---
printf -v COST_FMT '$%.2f' "$COST" 2>/dev/null || COST_FMT='$0.00'

# --- Duree de session ---
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))
if [ "$MINS" -gt 0 ]; then
  DURATION_FMT="${MINS}m ${SECS}s"
else
  DURATION_FMT="${SECS}s"
fi

# --- Mode serveur : état PM2 de l'app dans laquelle on se trouve ---
# Si le dossier courant est celui d'une app gérée par PM2 (ou un de ses sous-dossiers), son
# état et son nombre de redémarrages s'affichent à côté de la branche.
APP_SEGMENT=""
if [ "$SRV_MODE" = 1 ] && [ -n "$CACHE_DIR" ] && [ -f "$CACHE_DIR/pm2-apps" ] && [ ! -L "$CACHE_DIR/pm2-apps" ] && [[ $DIR == /* ]]; then
  _best=0; _bn=""; _bs=""; _br=0
  while IFS='|' read -r _ac _an _as _ar; do
    [ -n "$_ac" ] || continue
    if [ "$DIR" = "$_ac" ] || [[ $DIR == "$_ac"/* ]]; then
      if [ "${#_ac}" -gt "$_best" ]; then _best=${#_ac}; _bn=$_an; _bs=$_as; _br=$_ar; fi
    fi
  done < "$CACHE_DIR/pm2-apps" 2>/dev/null
  if [ "$_best" -gt 0 ]; then
    clean _bs; is_uint "$_br" || _br=0
    case $_bs in
      online)  APP_SEGMENT="${GRAY}pm2${RST} ${BGREEN}● en ligne${RST}" ;;
      errored) APP_SEGMENT="${GRAY}pm2${RST} ${BOLD}${BRED}● en erreur${RST}" ;;
      stopped|stopping) APP_SEGMENT="${GRAY}pm2${RST} ${BYELLOW}● arrêtée${RST}" ;;
      *)       APP_SEGMENT="${GRAY}pm2 ● ${_bs}${RST}" ;;
    esac
    [ "$_br" -gt 0 ] && APP_SEGMENT+=" ${DIM}${GRAY}↺${_br}${RST}"
  fi
fi

# Assemblage ligne 2
SEGS=(); PRIOS=()
SEGS+=("$BAR_SEGMENT");                    PRIOS+=(0)
# Coût de la session : suit COUTS. Durée : sur un poste seulement (une session de maintenance
# dure des heures, le chiffre ne décide de rien).
_seg_cost="${YELLOW}${COST_FMT}${RST}"; [ "$OPT_COSTS" = 1 ] || _seg_cost=""
_seg_dur="${GRAY}${DURATION_FMT}${RST}"; [ "$SRV_MODE" = 1 ] && _seg_dur=""
SEGS+=("$_seg_cost");                      PRIOS+=(4)
SEGS+=("$_seg_dur");                       PRIOS+=(5)
SEGS+=("$GIT_SEGMENT");                    PRIOS+=(2)
SEGS+=("$APP_SEGMENT");                    PRIOS+=(1)
fit LINE2 "$MAXW"

# ============================================================================
# LIGNE 3 : Usage reel (5h + 7j + Fable 7j) et couts
# ============================================================================
# Pourcentages et fins de fenêtre : ceux que Claude Code transmet (rate_limits), qui sont ceux
# du compte RÉELLEMENT utilisé par la session — sur un serveur où le jeton vient de l'environnement, le
# fichier .credentials.json est celui d'un autre compte. À défaut (début de session, Claude
# Code ancien), valeurs de l'API en cache. Le quota Fable et les coûts viennent du cache, tenu
# à jour en arrière-plan.
C_P5=""; C_R5=""; C_P7=""; C_R7=""; PCT_FABLE=""; WEEK_COST=0; BLOCK_COST=0
if { [ "$OPT_QUOTA_API" = 1 ] || [ "$OPT_COSTS" = 1 ]; } && cache_line _us usage; then
  IFS='|' read -r _uv _ue _u1 _u2 _u3 _u4 _u5 _u6 _u7 <<< "$_us"
  if [ "$_uv" = v3 ]; then
    if [ "$OPT_QUOTA_API" = 1 ]; then
      is_num "$_u1" && C_P5=$_u1
      is_uint "$_u2" && C_R5=$_u2
      is_num "$_u3" && C_P7=$_u3
      is_uint "$_u4" && C_R7=$_u4
      is_num "$_u5" && PCT_FABLE=$_u5
    fi
    is_num "$_u6" && WEEK_COST=$_u6
    is_num "$_u7" && BLOCK_COST=$_u7
  fi
fi
# Fenêtre 5 h : celle de Claude Code, sinon celle du cache si elle n'est pas échue.
PCT_5H=""; RESET_5H=""
if [ -n "$RL5_PCT" ] && [ -n "$RL5_RESET" ] && [ "$RL5_RESET" -gt "$NOW" ]; then PCT_5H=$RL5_PCT; RESET_5H=$RL5_RESET
elif [ -n "$C_P5" ] && [ -n "$C_R5" ] && [ "$C_R5" -gt "$NOW" ]; then PCT_5H=$C_P5; RESET_5H=$C_R5; fi
PCT_7D=${RL7_PCT:-$C_P7}
# Sur un serveur, aucun quota connu (ni transmis par Claude Code, ni reçu de l'API) : plutôt
# pas de ligne qu'un « 0 % » qui ne dit rien.
_sans_quota=0
[ -z "$PCT_7D" ] && [ -z "$PCT_FABLE" ] && _sans_quota=1
RESET_7D=${RL7_RESET:-$C_R7}

# Quota 5h : vide si aucune fenetre 5h en cours (segment masque, comme Fable)
PCT_5H_INT=""
[ -n "$PCT_5H" ] && round_to PCT_5H_INT "$PCT_5H" ""
round_to PCT_7D_INT "${PCT_7D:-0}" 0
# Quota Fable : vide si le compte est sans limite dediee (segment masque)
PCT_FABLE_INT=""
[ -n "$PCT_FABLE" ] && round_to PCT_FABLE_INT "$PCT_FABLE" ""

# --- Mini-barre ▰▱ (10 blocs, 5 quand la place manque) ---
mini_bar() {
  local -n _mb_out=$1
  local pct=${2:-0} color=$3 width=${4:-10} f e bf be
  f=$((pct * width / 100))
  [ "$f" -gt "$width" ] && f=$width
  e=$((width - f))
  rep bf "▰" "$f"
  rep be "▱" "$e"
  _mb_out="${color}${bf}${DIM}${GRAY}${be}${RST}"
}

# --- Couleur selon seuil ---
usage_color() {
  local -n _uc_out=$1
  if [ "$2" -ge 90 ]; then _uc_out=$BRED
  elif [ "$2" -ge 70 ]; then _uc_out=$BYELLOW
  else _uc_out=$BGREEN; fi
}
usage_color COLOR_5H "${PCT_5H_INT:-0}"
usage_color COLOR_7D "$PCT_7D_INT"

# --- Timer 5h ---
TIMER_5H="--"
if [ -n "$RESET_5H" ] && [ "$RESET_5H" -gt "$NOW" ]; then
  _r=$((RESET_5H - NOW))
  TIMER_5H="$((_r / 3600))h$(((_r % 3600) / 60))m"
fi

# --- Timer 7j ---
TIMER_7D="--"
if [ -n "$RESET_7D" ] && [ "$RESET_7D" -gt "$NOW" ]; then
  _r=$((RESET_7D - NOW))
  if [ $((_r / 86400)) -gt 0 ]; then TIMER_7D="$((_r / 86400))j $(((_r % 86400) / 3600))h"
  else TIMER_7D="$((_r / 3600))h $(((_r % 3600) / 60))m"; fi
fi

# --- Couts formates ---
printf -v WEEK_COST_FMT '$%.2f' "$WEEK_COST" 2>/dev/null || WEEK_COST_FMT='$0.00'
printf -v BLOCK_COST_FMT '$%.2f' "$BLOCK_COST" 2>/dev/null || BLOCK_COST_FMT='$0.00'

# --- Compte, en mode serveur : savoir quel abonnement la session consomme ---
ACCOUNT_SEG=""
if [ "$SRV_MODE" = 1 ]; then
  _acc=""
  if [[ ${STATUSLINE_ACCOUNT:-} =~ ^[A-Za-z0-9._-]{1,24}$ ]]; then _acc=$STATUSLINE_ACCOUNT
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _acc=${CLAUDE_CONFIG_DIR%/}; _acc=${_acc##*/}; _acc=${_acc#.claude-}; _acc=${_acc#.claude}
    [[ $_acc =~ ^[A-Za-z0-9._-]{1,24}$ ]] || _acc=""
  fi
  [ -n "$_acc" ] && ACCOUNT_SEG="${GRAY}compte${RST} ${WHITE}${_acc}${RST}"
fi

# --- Assemblage : complet, puis mini-barres courtes, puis sans coûts, puis sans barres ---
# Le segment 5h est masque (separateur compris) tant qu'aucune fenetre 5h n'est en cours.
build_line3() {
  local w=$1 costs=$2 b5 b7 s5="" s7 sf=""
  # L'usage 5 h n'est pas affiché sur un serveur (décision du 13/11) : le 7 j et le quota Fable
  # y suffisent.
  if [ -n "$PCT_5H_INT" ] && [ "$SRV_MODE" != 1 ]; then
    s5="${WHITE}5h${RST}"
    if [ "$w" -gt 0 ]; then mini_bar b5 "$PCT_5H_INT" "$COLOR_5H" "$w"; s5+=" ${b5}"; fi
    s5+=" ${COLOR_5H}${BOLD}${PCT_5H_INT}%${RST} ${DIM}${CYAN}${TIMER_5H}${RST}"
    [ "$costs" = 1 ] && s5+=" ${BYELLOW}${BLOCK_COST_FMT}${RST}"
  fi
  s7="${WHITE}7j${RST}"
  if [ "$w" -gt 0 ]; then mini_bar b7 "$PCT_7D_INT" "$COLOR_7D" "$w"; s7+=" ${b7}"; fi
  s7+=" ${COLOR_7D}${BOLD}${PCT_7D_INT}%${RST} ${DIM}${CYAN}${TIMER_7D}${RST}"
  [ "$costs" = 1 ] && s7+=" ${BYELLOW}${WEEK_COST_FMT}${RST}"
  # Segment Fable 7j : juste le pourcentage (limite hebdo dediee au modele)
  if [ -n "$PCT_FABLE_INT" ]; then
    usage_color _cf "$PCT_FABLE_INT"
    sf="${GOLD}Fable${RST} ${_cf}${BOLD}${PCT_FABLE_INT}%${RST}"
  fi
  SEGS=("$s5" "$s7" "$sf" "$ACCOUNT_SEG"); PRIOS=(0 0 1 2)
}
_costs=$OPT_COSTS
for _try in "10 $_costs" "5 $_costs" "5 0" "0 0"; do
  build_line3 ${_try% *} ${_try#* }
  LINE3=""
  for _i in "${!SEGS[@]}"; do
    [ -n "${SEGS[$_i]}" ] || continue
    if [ -n "$LINE3" ]; then LINE3+="${SEP}${SEGS[$_i]}"; else LINE3="${SEGS[$_i]}"; fi
  done
  vlen _w "$LINE3"
  [ "$_w" -le "$MAXW" ] && break
done
[ "$_w" -le "$MAXW" ] || fit LINE3 "$MAXW"

# --- Sur un serveur : contexte, quotas, git et app sur UNE seule ligne ---
# Trois lignes au lieu de quatre (décision du 13/11) : serveur, modèle et dossier, puis celle-ci.
# Quand la place manque : la mini-barre du quota raccourcit puis s'efface, la barre de contexte
# raccourcit, puis les segments partent du moins utile au plus utile (état PM2 quand l'app est
# en ligne, compte, branche, quota Fable). Le contexte et le quota 7 j restent toujours. Une
# app à l'arrêt ou en erreur reste affichée jusqu'au bout. Sans quota connu, pas de « 0 % ».
if [ "$SRV_MODE" = 1 ]; then
  _app_prio=5
  case $APP_SEGMENT in ''|*"en ligne"*) ;; *) _app_prio=1 ;; esac
  for _try in "15 10" "15 5" "10 5" "10 0"; do
    barre_contexte _bar "${_try% *}"
    build_line3 "${_try#* }" "$_costs"
    _s7=${SEGS[1]}; _sf=${SEGS[2]}; _sa=${SEGS[3]}
    if [ "$_sans_quota" = 1 ]; then _s7=""; _sf=""; fi
    SEGS=("$_bar" "$_seg_cost" "$_s7" "$_sf" "$GIT_SEGMENT" "$APP_SEGMENT" "$_sa")
    PRIOS=(0 6 0 2 3 "$_app_prio" 4)
    LINE2=""
    for _i in "${!SEGS[@]}"; do
      [ -n "${SEGS[$_i]}" ] || continue
      if [ -n "$LINE2" ]; then LINE2+="${SEP}${SEGS[$_i]}"; else LINE2="${SEGS[$_i]}"; fi
    done
    vlen _w "$LINE2"
    [ "$_w" -le "$MAXW" ] && break
  done
  [ "$_w" -le "$MAXW" ] || fit LINE2 "$MAXW"
  LINE3=""
fi

# Ligne du serveur (définie plus haut, avant la voie rapide).
ligne_serveur

# ============================================================================
# RAFRAÎCHISSEMENT : lancé en arrière-plan si un cache est périmé
# ============================================================================
# Détaché du rendu (setsid quand il existe), les trois descripteurs fermés : Claude Code
# n'attend pas sa fin et peut annuler le rendu sans l'interrompre. Le jeton de l'environnement, s'il y en
# a un, lui est passé par un tube, jamais en argument ni par l'environnement.
if [ -n "$CACHE_DIR" ] && [ -x "${BASH_SOURCE[0]:-}" ]; then
  _need=0
  { [ "$OPT_QUOTA_API" = 1 ] || [ "$OPT_COSTS" = 1 ]; } && is_stale usage "$USAGE_TTL" && _need=1
  [ "$OPT_STATUS" = 1 ] && is_stale statut "$STATUS_TTL" && _need=1
  [ "$SRV_MODE" = 1 ] && is_stale serveur "$SERVER_TTL" && _need=1
  # Le jeton ne quitte ce processus que si l'API des quotas est interrogée.
  _tok=""; [ "$OPT_QUOTA_API" = 1 ] && _tok=$_ENV_TOKEN
  if [ "$_need" = 1 ] && ! refresh_running; then
    if command -v setsid >/dev/null 2>&1; then
      ( printf '%s' "$_tok" | setsid "${BASH_SOURCE[0]}" --rafraichir "$VERSION" "$RL5_RESET" "$RL7_RESET" >/dev/null 2>&1 & ) >/dev/null 2>&1
    else
      ( printf '%s' "$_tok" | "${BASH_SOURCE[0]}" --rafraichir "$VERSION" "$RL5_RESET" "$RL7_RESET" >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
fi
_ENV_TOKEN=""; _tok=""

# ============================================================================
# SORTIE
# ============================================================================
# printf '%s' : le texte part tel quel, aucune séquence n'est interprétée à ce stade.
# Trame pour la voie rapide (serveur seulement) : date, largeur, les trois lignes, puis l'entrée
# sans sa durée. Écrite directement : un lecteur qui tomberait sur une trame incomplète la
# refuse (entrée différente) et refait un rendu complet.
if [ "$SRV_MODE" = 1 ] && [ -n "$CACHE_DIR" ] && [ "$SESSION_ID" != "defaut" ]; then
  cle_entree _cle
  printf 'v3|%s|%s\n%s\n%s\n%s\n%s' "$NOW" "${COLUMNS:-}" "$LINE1" "$LINE2" "$LINE3" "$_cle" > "$CACHE_DIR/trame-$SESSION_ID" 2>/dev/null
fi
[ -n "$LINE0" ] && printf '%s\n' "$LINE0"
printf '%s\n' "$LINE1" "$LINE2"
[ -n "$LINE3" ] && printf '%s\n' "$LINE3"
exit 0
