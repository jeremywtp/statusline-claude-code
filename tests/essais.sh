#!/usr/bin/env bash
# ============================================================================
# Banc d'essai de statusline.sh
#
# Tout se passe dans un dossier temporaire : faux profil Claude, faux curl / pm2 / ps / df,
# fausse racine système pour le mode serveur. Aucun appel réseau, aucun vrai jeton, rien
# n'est lu ni écrit dans le vrai profil.
#
# Usage : tests/essais.sh            (toute la suite)
#         tests/essais.sh -v         (affiche aussi les rendus)
# Code de sortie : 0 si tout passe, 1 sinon.
# ============================================================================
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && exec "$b" "$0" "$@"; done
  echo "bash 4 ou plus récent est requis" >&2; exit 2
fi
set -u
VERBEUX=0; [ "${1:-}" = "-v" ] && VERBEUX=1
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/sl-essais.XXXXXX") || exit 2
S=$(cd "$S" && pwd -P)
VRAI_PATH=$PATH
VRAI_GIT=$(command -v git)
UID_NUM=$(id -u)

nettoyer() {
  # Caches que la version de référence (la base) pose dans /tmp pour le profil du banc.
  [ -n "${HASH_PROFIL:-}" ] && find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-*" -delete 2>/dev/null
  [ -n "$S" ] && [ -d "$S" ] && [[ $S == */sl-essais.* ]] && rm -rf -- "$S"
}
trap nettoyer EXIT

# ----------------------------------------------------------------------------
# Décor
# ----------------------------------------------------------------------------
mkdir -p "$S/bin" "$S/home/.claude/projects/p1" "$S/sl" "$S/out" "$S/proj/site" "$S/racine/etc" "$S/racine/proc/pressure" \
  "$S/racine/sys/devices/system/cpu" "$S/racine/var/run" "$S/racine/var/lib/update-notifier" "$S/apps/site.fr/src"
export BANC="$S"

cat > "$S/bin/curl" <<'FAUX'
#!/bin/bash
# Faux curl : note ses arguments, ce qu'il lit sur son entrée (-K -) et si un jeton traîne
# dans son environnement. Répond comme l'API des quotas et comme status.claude.com.
printf '%s\n' "$*" >> "$BANC/out/curl-argv.log"
printf 'env=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-absent}" >> "$BANC/out/curl-env.log"
out=""; prev=""; conf=0
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-K" ] && [ "$a" = "-" ] && conf=1
  prev="$a"
done
[ "$conf" = 1 ] && cat >> "$BANC/out/curl-stdin.log"
[ -n "${FAUX_LENTEUR:-}" ] && sleep "$FAUX_LENTEUR"
case "$*" in
  *oauth/usage*)
    code=200; [ -f "$BANC/out/api-code" ] && code=$(cat "$BANC/out/api-code")
    if [ -n "$out" ]; then cat "$BANC/out/api-corps" > "$out" 2>/dev/null; printf '%s' "$code"; else cat "$BANC/out/api-corps"; fi ;;
  *status.claude.com*)
    [ -f "$BANC/out/statut-corps" ] && cat "$BANC/out/statut-corps" || exit 22 ;;
esac
FAUX

cat > "$S/bin/git" <<FAUX
#!/bin/bash
# Enveloppe de git : note si un jeton est visible dans son environnement, ne fait pas de vrai
# fetch (et peut le faire durer), passe le reste au vrai git.
printf 'env=%s args=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN:-absent}" "\$*" >> "\$BANC/out/git.log"
for a in "\$@"; do
  if [ "\$a" = "fetch" ]; then [ -n "\${FAUX_FETCH_LENT:-}" ] && sleep "\$FAUX_FETCH_LENT"; exit 0; fi
done
exec "$VRAI_GIT" "\$@"
FAUX

cat > "$S/bin/jq" <<FAUX
#!/bin/bash
# Enveloppe de jq : note chaque appel, puis passe la main au vrai.
echo appel >> "\$BANC/out/jq.log"
exec "$(command -v jq)" "\$@"
FAUX

cat > "$S/bin/pm2" <<'FAUX'
#!/bin/bash
# Faux pm2 : `jlist` rend trois apps, avec l'environnement complet de chacune (un secret).
[ "$1" = "jlist" ] || exit 0
echo ">>>> In-memory PM2 is out-of-date, do: \$ pm2 update"
cat "$BANC/out/pm2-jlist.json"
FAUX

cat > "$S/bin/ps" <<'FAUX'
#!/bin/bash
# Faux ps : un build Next en cours, deux sessions Claude sur deux terminaux, et le plus gros
# consommateur de mémoire quand le banc en fournit un (ps-rss).
case "$*" in
  *"rss=,pid=,comm="*) cat "$BANC/out/ps-rss" 2>/dev/null ;;
  *"tty=,args="*) printf 'pts/0    /home/ubuntu/.local/share/claude/versions/2.1.323 --session-id x\npts/3    claude\n?        /usr/sbin/nginx\npts/3    bash\n' ;;
  *"args="*) printf 'sh -c node scripts/verif.js && next build\nnode /var/www/apps/site.fr/node_modules/.bin/next build\nnode server.js\n/usr/sbin/nginx -g daemon\n' ;;
esac
FAUX

cat > "$S/bin/df" <<'FAUX'
#!/bin/bash
# Faux df : 78 % sur la racine, 41 % sur /mnt/data.
m="${*: -1}"; pct=78; [ "$m" = "/mnt/data" ] && pct=41
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 %s 22 %s%% %s\n' "$pct" "$pct" "$m"
FAUX
chmod +x "$S/bin/"*

export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" PATH="$S/bin:$VRAI_PATH"
unset XDG_CACHE_HOME XDG_CONFIG_HOME CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY COLUMNS CLAUDE_CODE_EFFORT_LEVEL STATUSLINE_OPERATOR STATUSLINE_ACCOUNT
CACHE="$HOME/.cache/claude-statusline"
if command -v sha256sum >/dev/null 2>&1; then HASH_PROFIL=$(printf '%s' "$CLAUDE_CONFIG_DIR" | sha256sum | cut -c1-8)
else HASH_PROFIL=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8); fi

printf '{"claudeAiOauth":{"accessToken":"JETON-FICHIER-FACTICE-0000000000"}}' > "$HOME/.claude/.credentials.json"
printf '{}' > "$HOME/.claude/settings.json"
printf '{"incidents":[],"components":[{"status":"operational"}],"scheduled_maintenances":[]}' > "$S/out/statut-corps"

iso() { python3 -I -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + sys.argv[2])' "$1" "$2"; }
MAINTENANT=$(date +%s)
api_normale() {  # fenêtre 5 h : finit dans 2 h ; fenêtre 7 j : finit dans 2 jours
  printf '{"five_hour":{"utilization":23.4,"resets_at":"%s"},"seven_day":{"utilization":41.2,"resets_at":"%s"},"limits":[{"kind":"weekly_scoped","percent":14,"scope":{"model":{"display_name":"Fable"}}}]}' \
    "$(iso $((MAINTENANT + 7200)) '.123456+00:00')" "$(iso $((MAINTENANT + 172800)) 'Z')" > "$S/out/api-corps"
  rm -f "$S/out/api-code"
}
api_normale

python3 -I "$REPO/tests/monter.py" "$REPO" "$REPO/statusline.sh" "$S/sl/v3.sh" > /dev/null || exit 2
python3 -I "$REPO/tests/monter.py" "$REPO" "$REPO/statusline.sh" "$S/sl/v3-serveur.sh" --racine "$S/racine" > /dev/null || exit 2
REF=0
if "$VRAI_GIT" -C "$REPO" show main:statusline.sh > "$S/sl/base-source.sh" 2>/dev/null; then
  python3 -I "$REPO/tests/monter.py" "$REPO" "$S/sl/base-source.sh" "$S/sl/base.sh" > /dev/null && REF=1
fi

# ----------------------------------------------------------------------------
# Outils
# ----------------------------------------------------------------------------
N_OK=0; N_KO=0
ok() { N_OK=$((N_OK + 1)); printf '  ok     %s\n' "$1"; }
ko() { N_KO=$((N_KO + 1)); printf '  ÉCHEC  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
verifie() { if eval "$2"; then ok "$1"; else ko "$1" "${3:-}"; fi; }
titre() { printf '\n%s\n' "$1"; }
texte() { sed $'s/\033\\[[0-9;]*m//g'; }
montrer() { [ "$VERBEUX" = 1 ] && sed 's/^/         | /' | texte; return 0; }

entree() {  # entree <fichier> [filtre jq appliqué à l'entrée type]
  jq -cn --arg d "$S/proj/site" '{model:{display_name:"Fable 5.2",id:"claude-fable-5-2"},workspace:{current_dir:$d},version:"2.1.323",
    cost:{total_cost_usd:1.24,total_duration_ms:202000},context_window:{used_percentage:40},effort:{level:"high"},fast_mode:false,
    session_id:"11111111-2222-3333-4444-555555555555"} | '"${2:-.}" > "$S/out/$1"
}
# rendre <script> <entrée> : rendu complet (la trame de la voie rapide est retirée avant).
rendre() { [ -d "$CACHE" ] && find "$CACHE" -name 'trame-*' -delete 2>/dev/null; "$1" < "$S/out/$2" 2> "$S/out/err.txt"; }
# enchainer <script> <entrée> : rendu tel que Claude Code l'enchaîne, trame conservée.
enchainer() { "$1" < "$S/out/$2" 2> "$S/out/err.txt"; }
vider_cache() { [ -d "$CACHE" ] && find "$CACHE" -type f -delete 2>/dev/null; [ -d "$CACHE" ] && find "$CACHE" -mindepth 1 -depth -type d -empty -delete 2>/dev/null; return 0; }
attendre() {  # attendre <fichier> [depuis] : l'arrière-plan a écrit <fichier> (daté d'au moins [depuis]) et rendu le verrou
  local i f v e reste
  for ((i = 0; i < 60; i++)); do
    f=$(find "$CACHE" -name "$1" 2>/dev/null | head -1)
    if [ -n "$f" ] && [ -z "$(find "$CACHE" -name 'verrou.d' 2>/dev/null)" ]; then
      IFS='|' read -r v e reste < "$f"
      [ "${e:-0}" -ge "${2:-0}" ] && return 0
    fi
    sleep 0.25
  done
  printf '         (attente dépassée : %s)\n' "$1" >&2
  return 1
}
perimer() { local f; for f in $(find "$CACHE" -name "$1" 2>/dev/null); do sed -i.bak -E 's/^v3\|[0-9]+/v3|1/' "$f" && rm -f "$f.bak"; done; }
chaud() {  # chaud <script> <entrée> <fichier attendu> : rendu, attente d'un cache RÉÉCRIT, rendu
  local t; t=$(date +%s)
  rendre "$1" "$2" > /dev/null; attendre "$3" "$t"; rendre "$1" "$2"
}
profil_cache() { find "$CACHE" -mindepth 1 -maxdepth 1 -type d | head -1; }
largeur_max() { texte | python3 -I -c 'import sys; print(max([len(l.rstrip("\n")) for l in sys.stdin] or [0]))'; }
horloge() { python3 -I -c 'import time; print(time.time())'; }

entree normal.json

# ----------------------------------------------------------------------------
titre "1. Rendu nominal"
# ----------------------------------------------------------------------------
avant_tmp=$(find /tmp/ -maxdepth 1 -name 'claude-sl-*' 2>/dev/null | sort)
avant_home=$(find "$HOME" -path "$HOME/.cache" -prune -o -print | sort)
rendre "$S/sl/v3.sh" normal.json > "$S/out/froid.txt"; code=$?
verifie "premier rendu, caches vides : code 0 et trois lignes" '[ "$code" = 0 ] && [ "$(wc -l < "$S/out/froid.txt")" -eq 3 ]'
verifie "rien sur la sortie d'erreur" '[ ! -s "$S/out/err.txt" ]' "$(head -2 "$S/out/err.txt")"
attendre usage; attendre statut
rendre "$S/sl/v3.sh" normal.json > "$S/out/chaud.txt"; montrer < "$S/out/chaud.txt"
T=$(texte < "$S/out/chaud.txt")
verifie "ligne 1 : modèle, effort, projet, version, statut" '[[ $(sed -n 1p <<< "$T") == "Fable 5.2 ▌▌▌▌▌ │ site │ v2.1.323 ●" ]]' "$(sed -n 1p <<< "$T")"
verifie "ligne 2 : contexte, coût, durée" '[[ $(sed -n 2p <<< "$T") == "██████░░░░░░░░░ 40% │ \$1.24 │ 3m 22s" ]]' "$(sed -n 2p <<< "$T")"
verifie "ligne 3 : quotas 5 h, 7 j et Fable venus de l'API" '[[ $(sed -n 3p <<< "$T") =~ ^5h\ ▰▰▱▱▱▱▱▱▱▱\ 23%\ (1h5[0-9]m|2h0m)\ \$0\.00\ │\ 7j\ ▰▰▰▰▱▱▱▱▱▱\ 41%\ (1j\ 23h|2j\ 0h)\ \$0\.00\ │\ Fable\ 14%$ ]]' "$(sed -n 3p <<< "$T")"
verifie "le statut de Claude est vert quand le service répond" 'grep -q $'"'"'\033\[38;5;82m●'"'"' "$S/out/chaud.txt"'

# ----------------------------------------------------------------------------
titre "2. Rien hors du cache privé"
# ----------------------------------------------------------------------------
verifie "aucun fichier créé dans /tmp" '[ "$(find /tmp/ -maxdepth 1 -name "claude-sl-*" 2>/dev/null | sort)" = "$avant_tmp" ]'
verifie "aucun fichier créé dans le profil ni ailleurs dans le dossier personnel" '[ "$(find "$HOME" -path "$HOME/.cache" -prune -o -print | sort)" = "$avant_home" ]'
droits=$(find "$CACHE" -exec stat -c '%a' {} + 2>/dev/null || find "$CACHE" -exec stat -f '%Lp' {} +)
verifie "cache : dossiers 700 et fichiers 600, rien d'autre" '[ -z "$(printf "%s\n" "$droits" | grep -v "^[67]00$")" ]' "$(printf '%s ' $droits)"
umask 002; vider_cache; chaud "$S/sl/v3.sh" normal.json usage > /dev/null; umask 022
droits=$(find "$CACHE" -exec stat -c '%a' {} + 2>/dev/null || find "$CACHE" -exec stat -f '%Lp' {} +)
verifie "idem quand la session a un masque ouvert au groupe (0002)" '[ -z "$(printf "%s\n" "$droits" | grep -v "^[67]00$")" ]' "$(printf '%s ' $droits)"
P=$(profil_cache); mv "$P" "$P.vrai"; mkdir "$S/piege"; ln -s "$S/piege" "$P"
rendre "$S/sl/v3.sh" normal.json > "$S/out/lien.txt"; sleep 1
verifie "un cache remplacé par un lien est refusé : rien n'y est écrit, la barre s'affiche" '[ -z "$(ls -A "$S/piege")" ] && [ "$(wc -l < "$S/out/lien.txt")" -eq 3 ]'
rm -f "$P"; mv "$P.vrai" "$P"
mkdir -p "$S/home/.claude-compte2"; cp "$HOME/.claude/.credentials.json" "$S/home/.claude-compte2/"
( export CLAUDE_CONFIG_DIR="$S/home/.claude-compte2"; rendre "$S/sl/v3.sh" normal.json > /dev/null; sleep 2 )
verifie "deux profils (CLAUDE_CONFIG_DIR) : deux dossiers de cache distincts, jamais de mélange" '[ "$(find "$CACHE" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ] && [ -z "$(find "$CACHE" -maxdepth 1 -type f)" ]' "$(ls "$CACHE" | tr '\n' ' ')"
P2=$(find "$CACHE" -mindepth 1 -maxdepth 1 -type d -name '*compte2'); [ -n "$P2" ] && find "$P2" -type f -delete && find "$P2" -depth -type d -empty -delete

# ----------------------------------------------------------------------------
titre "3. Jeton"
# ----------------------------------------------------------------------------
verifie "le jeton n'apparaît dans aucune ligne de commande de curl" '! grep -q "JETON" "$S/out/curl-argv.log"' "$(grep -c JETON "$S/out/curl-argv.log") appel(s)"
verifie "il arrive à curl par son entrée standard" 'grep -q "Authorization: Bearer JETON-FICHIER-FACTICE" "$S/out/curl-stdin.log"'
: > "$S/out/curl-stdin.log"; : > "$S/out/curl-env.log"; : > "$S/out/git.log"; vider_cache
CLAUDE_CODE_OAUTH_TOKEN="JETON-DU-LANCEUR-FACTICE-1111111111" chaud "$S/sl/v3.sh" normal.json usage > /dev/null
verifie "jeton reçu par l'environnement : c'est lui qui interroge l'API, pas celui du fichier" 'grep -q "Bearer JETON-DU-LANCEUR" "$S/out/curl-stdin.log" && ! grep -q "JETON-FICHIER" "$S/out/curl-stdin.log"'
verifie "ni curl ni git n'héritent du jeton par l'environnement" '! grep -q "JETON" "$S/out/curl-env.log" "$S/out/git.log" && [ -s "$S/out/git.log" ] && [ -s "$S/out/curl-env.log" ]'
verifie "le jeton n'est écrit nulle part dans le cache" '! grep -rq "JETON" "$CACHE"'
printf '{"claudeAiOauth":{"accessToken":"JETON\\"\\nheader = \\"X-Injecte: 1"}}' > "$HOME/.claude/.credentials.json"
: > "$S/out/curl-stdin.log"; vider_cache; chaud "$S/sl/v3.sh" normal.json usage > /dev/null
verifie "un jeton contenant un guillemet ou un saut de ligne ne part pas" '! grep -q "X-Injecte" "$S/out/curl-stdin.log" "$S/out/curl-argv.log"'
printf '{"claudeAiOauth":{"accessToken":"JETON-FICHIER-FACTICE-0000000000"}}' > "$HOME/.claude/.credentials.json"

# ----------------------------------------------------------------------------
titre "4. Injection par l'affichage"
# ----------------------------------------------------------------------------
sans_sequence() { ! texte < "$1" | LC_ALL=C grep -q $'[\001-\010\013-\037\177]'; }
mkdir -p "$S/proj/"'x\033[41;97m PROD \033[0m\033]0;TITRE\007'
jq -cn --arg d "$S/proj/"'x\033[41;97m PROD \033[0m\033]0;TITRE\007' '{model:{display_name:"Fable 5.2"},workspace:{current_dir:$d},version:"2.1.323",effort:{level:"high"},session_id:"22222222-2222-3333-4444-555555555555"}' > "$S/out/inj1.json"
rendre "$S/sl/v3.sh" inj1.json > "$S/out/inj1.txt"; montrer < "$S/out/inj1.txt"
verifie "nom de dossier portant « \\033[…m » écrit en clair : affiché tel quel, rien d'interprété" 'sans_sequence "$S/out/inj1.txt" && grep -qF "x\\033[41;97m" "$S/out/inj1.txt"'
jq -cn '{model:{display_name:"Fa\u001b]52;c;QUJD\u0007ble\u009b31m"},workspace:{current_dir:"/tmp/\u001b[5mx\u0000y"},version:"2.1\u001b[31m",agent:{name:"a\u001b]0;T\u0007\nligne-en-trop"},
  session_name:"s‮\u001b[2J",vim:{mode:"NORMAL\u001b[0m"},effort:{level:"high\u001b"},session_id:"../../../etc/passwd",transcript_path:"/x\ny"}' > "$S/out/inj2.json"
rendre "$S/sl/v3.sh" inj2.json > "$S/out/inj2.txt"; code=$?; montrer < "$S/out/inj2.txt"
verifie "octets ESC, BEL, NUL, CSI 8 bits et sauts de ligne dans chaque champ : aucun ne passe, trois lignes" '[ "$code" = 0 ] && sans_sequence "$S/out/inj2.txt" && [ "$(wc -l < "$S/out/inj2.txt")" -eq 3 ] && ! LC_ALL=C grep -q $'"'"'\302\233'"'"' "$S/out/inj2.txt"'
verifie "un identifiant de session en forme de chemin ne sort pas du cache" '[ -z "$(find "$CACHE" -name "*passwd*")" ] && [ ! -e "$CACHE/../../../etc" ]'
P=$(profil_cache)
printf 'v3|%s|true|0|0|0|0|0|0|%s\n%s\n%s\n' "$MAINTENANT" "$MAINTENANT" "$S/proj/site" $'main\033]0;VOISIN\007\033[5;41m ALERTE' > "$P/git-11111111-2222-3333-4444-555555555555"
sed -i.bak -E "s/^v3\|[0-9]+/v3|$(date +%s)/" "$P/git-11111111-2222-3333-4444-555555555555"; rm -f "$P/"*.bak
rendre "$S/sl/v3.sh" normal.json > "$S/out/inj3.txt"; montrer < "$S/out/inj3.txt"
verifie "séquences posées dans un fichier de cache : retirées à la lecture" 'sans_sequence "$S/out/inj3.txt" && grep -q "ALERTE" "$S/out/inj3.txt"'

# ----------------------------------------------------------------------------
titre "5. Injection par le calcul"
# ----------------------------------------------------------------------------
TEMOIN="$S/out/TEMOIN"
printf 'v3|%s|true|a[$(touch %s)]|0|0|0|0|0|0\n%s\nmain\n' "$(date +%s)" "$TEMOIN" "$S/proj/site" > "$P/git-11111111-2222-3333-4444-555555555555"
printf 'v3|%s|a[$(touch %s)]|99999999999999|x[$(touch %s)]|010|1e999|$(touch %s)|`touch %s`\n' "$(date +%s)" "$TEMOIN" "$TEMOIN" "$TEMOIN" "$TEMOIN" > "$P/usage"
printf 'v3|%s|$(touch %s)\n' "$(date +%s)" "$TEMOIN" > "$P/statut"
rendre "$S/sl/v3.sh" normal.json > "$S/out/calc1.txt"; code=$?
verifie "caches dont les nombres sont des expressions : code 0, trois lignes, rien d'exécuté" '[ "$code" = 0 ] && [ "$(wc -l < "$S/out/calc1.txt")" -eq 3 ] && [ ! -e "$TEMOIN" ]'
jq -cn --arg t "$TEMOIN" '{model:{display_name:"Opus 5.5"},workspace:{current_dir:"/"},version:"1",cost:{total_cost_usd:("a[$(touch "+$t+")]"),total_duration_ms:("x[$(touch "+$t+")]")},
  context_window:{used_percentage:("a[$(touch "+$t+")]")},rate_limits:{five_hour:{used_percentage:("b[$(touch "+$t+")]"),resets_at:("c[$(touch "+$t+")]")},seven_day:{used_percentage:"08",resets_at:"0777"}}}' > "$S/out/calc2.json"
rendre "$S/sl/v3.sh" calc2.json > "$S/out/calc2.txt"; code=$?; montrer < "$S/out/calc2.txt"
verifie "entrée dont les nombres sont des expressions ou commencent par 0 : code 0, rien d'exécuté" '[ "$code" = 0 ] && [ "$(wc -l < "$S/out/calc2.txt")" -eq 3 ] && [ ! -e "$TEMOIN" ] && [ ! -s "$S/out/err.txt" ]' "$(head -2 "$S/out/err.txt")"
vider_cache

# ----------------------------------------------------------------------------
titre "6. Entrées dégradées"
# ----------------------------------------------------------------------------
for cas in vide:'' invalide:'{"model":' tableau:'[1,2,3]' nuls:'{"model":null,"workspace":null,"cost":null,"context_window":{"used_percentage":null},"rate_limits":null}' chaine:'"bonjour"'; do
  nom=${cas%%:*}; printf '%s' "${cas#*:}" > "$S/out/deg.json"
  rendre "$S/sl/v3.sh" deg.json > "$S/out/deg.txt"; code=$?
  verifie "entrée $nom : code 0, trois lignes, pas d'erreur" '[ "$code" = 0 ] && [ "$(wc -l < "$S/out/deg.txt")" -eq 3 ] && [ ! -s "$S/out/err.txt" ]' "$(head -2 "$S/out/err.txt")"
done
( export HOME=/dossier-inexistant; unset CLAUDE_CONFIG_DIR; rendre "$S/sl/v3.sh" normal.json > "$S/out/sanshome.txt" )
verifie "dossier personnel introuvable (pas de cache possible) : la barre s'affiche quand même" '[ "$(wc -l < "$S/out/sanshome.txt")" -eq 3 ]'

# ----------------------------------------------------------------------------
titre "7. Largeur"
# ----------------------------------------------------------------------------
entree large.json '.agent = {name:"relecteur-de-securite"} | .vim = {mode:"INSERT"} | .model.display_name = "Fable 5.2" | .fast_mode = true | .rate_limits = {five_hour:{used_percentage:91,resets_at:(now + 3000 | floor)},seven_day:{used_percentage:72,resets_at:(now + 400000 | floor)}}'
( cd "$S/proj/site" && "$VRAI_GIT" init -q -b une-branche-au-nom-vraiment-tres-long-pour-voir . && : > a && : > b && "$VRAI_GIT" add a ) 2>/dev/null
chaud "$S/sl/v3.sh" large.json usage > /dev/null
depasse=""
for c in 34 40 50 60 70 80 100 120 200; do
  COLUMNS=$c rendre "$S/sl/v3.sh" large.json > "$S/out/l$c.txt"
  w=$(largeur_max < "$S/out/l$c.txt"); [ "$w" -le "$c" ] || depasse+=" $c($w)"
  [ "$VERBEUX" = 1 ] && { printf '         --- %s colonnes ---\n' "$c"; montrer < "$S/out/l$c.txt"; }
done
verifie "de 34 à 200 colonnes, aucune ligne ne dépasse la largeur du terminal" '[ -z "$depasse" ]' "dépassements :$depasse"
verifie "à 200 colonnes rien n'est retiré (agent, vim, coûts, branche)" 'texte < "$S/out/l200.txt" | grep -q "@relecteur-de-securite" && texte < "$S/out/l200.txt" | grep -q "\[I\]" && texte < "$S/out/l200.txt" | grep -q "une-branche-au-nom"'
verifie "à 34 colonnes il reste le modèle, le contexte et les deux quotas" 'T=$(texte < "$S/out/l34.txt"); [[ $T == *"Fable 5.2"* && $T == *"40%"* && $T == *"5h"*"91%"* && $T == *"7j"*"72%"* ]]' "$(texte < "$S/out/l34.txt" | tr '\n' '/')"
verifie "sans COLUMNS, rendu complet comme la base" '[ "$(rendre "$S/sl/v3.sh" large.json | largeur_max)" -gt 80 ]'

# ----------------------------------------------------------------------------
titre "8. Quotas"
# ----------------------------------------------------------------------------
entree rl.json '.rate_limits = {five_hour:{used_percentage:61.6,resets_at:(now + 3660 | floor)},seven_day:{used_percentage:88.2,resets_at:(now + 90000 | floor)}}'
T=$(rendre "$S/sl/v3.sh" rl.json | texte | sed -n 3p)
verifie "les pourcentages transmis par Claude Code priment sur ceux du cache" '[[ $T =~ ^5h\ ▰▰▰▰▰▰▱▱▱▱\ 62%\ 1h[01]m && $T == *"7j ▰▰▰▰▰▰▰▰▱▱ 88% 1j 1h"* ]]' "$T"
printf '{"five_hour":null,"limits":[{"kind":"weekly_all","percent":37,"resets_at":"%s"}]}' "$(iso $((MAINTENANT + 172800)) 'Z')" > "$S/out/api-corps"
vider_cache; T=$(chaud "$S/sl/v3.sh" normal.json usage | texte | sed -n 3p)
verifie "five_hour nul : segment 5 h masqué, 7 j lu dans limits[]" '[[ $T == "7j ▰▰▰▱▱▱▱▱▱▱ 37% 1j 23h \$0.00" ]]' "$T"
api_normale; perimer usage; chaud "$S/sl/v3.sh" normal.json usage > /dev/null
echo 500 > "$S/out/api-code"; echo "<html>erreur</html>" > "$S/out/api-corps"; perimer usage
T=$(chaud "$S/sl/v3.sh" normal.json usage | texte | sed -n 3p)
verifie "API en erreur 500 : les dernières valeurs connues restent affichées" '[[ $T == "5h ▰▰▱▱▱▱▱▱▱▱ 23%"*"7j ▰▰▰▰▱▱▱▱▱▱ 41%"*"Fable 14%" ]]' "$T"
echo 429 > "$S/out/api-code"; perimer usage; : > "$S/out/curl-argv.log"
chaud "$S/sl/v3.sh" normal.json usage > /dev/null; perimer usage; chaud "$S/sl/v3.sh" normal.json usage > /dev/null
verifie "réponse 429 : un seul appel, puis pause de 10 minutes" '[ "$(grep -c "oauth/usage" "$S/out/curl-argv.log")" -eq 1 ] && [ -n "$(find "$CACHE" -name usage-pause)" ]' "$(grep -c 'oauth/usage' "$S/out/curl-argv.log") appel(s)"
api_normale; vider_cache
rm -f "$S/out/statut-corps"; T=$(chaud "$S/sl/v3.sh" normal.json statut)
verifie "statut de Claude injoignable : point gris, pas un faux vert" 'grep -q $'"'"'\033\[2m\033\[38;5;244m●'"'"' <<< "$T"'
printf '{"incidents":[{"impact":"major","resolved_at":null}],"components":[],"scheduled_maintenances":[]}' > "$S/out/statut-corps"
perimer statut; T=$(chaud "$S/sl/v3.sh" normal.json statut)
verifie "incident majeur en cours : point orange" 'grep -q $'"'"'\033\[38;5;208m●'"'"' <<< "$T"'
printf '{"incidents":[],"components":[{"status":"operational"}],"scheduled_maintenances":[]}' > "$S/out/statut-corps"

# ----------------------------------------------------------------------------
titre "9. Coûts"
# ----------------------------------------------------------------------------
ligne_jsonl() {  # ligne_jsonl <il y a N secondes> <requête> <modèle> <input> <output> <cache 5 min> <cache lu>
  jq -cn --arg ts "$(iso $((MAINTENANT - $1)) '.000Z')" --arg r "$2" --arg m "$3" --argjson i "$4" --argjson o "$5" --argjson c "$6" --argjson cr "$7" \
    '{type:"assistant",timestamp:$ts,requestId:$r,message:{model:$m,usage:{input_tokens:$i,output_tokens:$o,cache_creation:{ephemeral_5m_input_tokens:$c,ephemeral_1h_input_tokens:0},cache_read_input_tokens:$cr}}}'
}
J1="$HOME/.claude/projects/p1/aaaaaaaa-0000-0000-0000-000000000001.jsonl"
J2="$HOME/.claude/projects/p1/aaaaaaaa-0000-0000-0000-000000000002.jsonl"
{ ligne_jsonl 3600 req1 claude-fable-5-2 1000 10 0 0          # ligne de streaming intermédiaire : ignorée
  ligne_jsonl 3600 req1 claude-fable-5-2 1000 2000 3000 100000  # 0,138 $
  echo '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"content":"\"type\":\"assistant\" cité dans un message"}}'
  ligne_jsonl 30000 req2 claude-opus-5-5 500000 10000 0 0       # 2,20 $ : dans la semaine, hors fenêtre 5 h
} > "$J1"
ligne_jsonl 1800 req4 claude-haiku-5-5 150000 1000 0 0 > "$J2"   # palier > 100 K : 0,075 + 0,0025 = 0,0775 $
vider_cache; T=$(chaud "$S/sl/v3.sh" normal.json usage | texte | sed -n 3p); montrer <<< "$T"
verifie "coûts : 5 h = 0,22 \$ et 7 j = 2,42 \$ (calcul à la main, doublon de streaming écarté, palier Haiku 5.5)" '[[ $T == *"\$0.22 │ 7j"*"\$2.42 │ Fable"* ]]' "$T"
if [ "$REF" = 1 ]; then
  Tb=$(rendre "$S/sl/base.sh" normal.json | texte | sed -n 3p)
  cout() { grep -oE '\$[0-9]+\.[0-9]{2}' <<< "$1" | tr '\n' ' '; }
  verifie "mêmes coûts que la base sur les mêmes transcriptions" '[ "$(cout "$T")" = "$(cout "$Tb")" ]' "nouvelle : $(cout "$T") / base : $(cout "$Tb")"
fi
x2=$(find "$CACHE" -name '*0002.jsonl.x'); avant=$(stat -c %Y "$x2" 2>/dev/null || stat -f %m "$x2")
sleep 1.1
# Une ligne à moitié écrite (session coupée en pleine réponse), puis une réponse complète.
printf '{"type":"assistant","timestamp":"2026-11-13T09:00:00.000Z","requestId":"req3","message":{"model":"claude-fable-5-2","usage":{"input_tok\n' >> "$J1"
ligne_jsonl 60 req5 claude-sonnet-5-5 100000 20000 0 0 >> "$J1"   # 0,40 $
perimer usage; T=$(chaud "$S/sl/v3.sh" normal.json usage | texte | sed -n 3p)
apres=$(stat -c %Y "$x2" 2>/dev/null || stat -f %m "$x2")
verifie "une ligne tronquée puis une réponse de plus : les coûts suivent (0,62 \$ et 2,82 \$)" '[[ $T == *"\$0.62 │ 7j"*"\$2.82 │ Fable"* ]]' "$T"
verifie "la transcription inchangée n'a pas été relue" '[ "$avant" = "$apres" ]'
if [ "$REF" = 1 ]; then
  find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-usage-*" -delete 2>/dev/null
  Tb=$(rendre "$S/sl/base.sh" normal.json | texte | sed -n 3p)
  printf '  note   la base, avec la ligne tronquée : %s(elle cesse de lire au premier JSON invalide)\n' "$(cout "$Tb")"
fi
# Corpus sans ligne tronquée pour la suite des comparaisons avec la base.
grep -v 'input_tok$' "$J1" > "$J1.propre"; mv "$J1.propre" "$J1"

# ----------------------------------------------------------------------------
titre "10. Le rendu n'attend ni le réseau ni git"
# ----------------------------------------------------------------------------
vider_cache; t0=$(horloge)
FAUX_LENTEUR=3 rendre "$S/sl/v3.sh" normal.json > "$S/out/lent.txt"
d=$(python3 -I -c 'import sys; print(int((float(sys.argv[2]) - float(sys.argv[1])) * 1000))' "$t0" "$(horloge)")
verifie "API et statut qui mettent 3 s à répondre : barre rendue en moins d'une seconde (${d} ms)" '[ "$d" -lt 1000 ] && [ "$(wc -l < "$S/out/lent.txt")" -eq 3 ]'
attendre usage
( cd "$S/proj/site" && "$VRAI_GIT" -c user.email=a@b -c user.name=x commit -qm 1 && "$VRAI_GIT" clone -q --bare . "$S/amont.git" && "$VRAI_GIT" remote add origin "$S/amont.git" && "$VRAI_GIT" fetch -q origin && "$VRAI_GIT" branch -q --set-upstream-to=origin/une-branche-au-nom-vraiment-tres-long-pour-voir ) > /dev/null 2>&1
rm -f "$(profil_cache)"/git-*; t0=$(horloge)
FAUX_FETCH_LENT=3 "$S/sl/v3.sh" < "$S/out/normal.json" 2>/dev/null | cat > "$S/out/fetch.txt"
d=$(python3 -I -c 'import sys; print(int((float(sys.argv[2]) - float(sys.argv[1])) * 1000))' "$t0" "$(horloge)")
verifie "git fetch qui dure 3 s : la sortie est rendue sans l'attendre (${d} ms)" '[ "$d" -lt 1000 ] && grep -q " fetch " "$S/out/git.log"'
if [ "$REF" = 1 ]; then
  find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-fetch-*" -delete 2>/dev/null
  rendre "$S/sl/base.sh" normal.json > /dev/null; find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-fetch-*" -delete 2>/dev/null
  t0=$(horloge); FAUX_FETCH_LENT=3 "$S/sl/base.sh" < "$S/out/normal.json" 2>/dev/null | cat > /dev/null
  d=$(python3 -I -c 'import sys; print(int((float(sys.argv[2]) - float(sys.argv[1])) * 1000))' "$t0" "$(horloge)")
  printf '  note   la base, même essai : sortie rendue au bout de %s ms\n' "$d"
fi

# ----------------------------------------------------------------------------
titre "11. Git"
# ----------------------------------------------------------------------------
( cd "$S/proj/site" && echo x >> a && : > c && "$VRAI_GIT" add c && mkdir -p d && : > d/e && : > d/f ) 2>/dev/null
rm -f "$(profil_cache)"/git-*; : > "$S/out/git.log"
T=$(rendre "$S/sl/v3.sh" normal.json | texte | sed -n 2p); montrer <<< "$T"
verifie "branche et compteurs (1 indexé, 1 modifié, 3 non suivis)" '[[ $T == *"* une-branche-au-nom-vraiment-tres-long-pour-voir +1 ~1 ?3"* ]]' "$T"
verifie "un seul appel à git par rendu, sans verrou ni moniteur de fichiers" '[ "$(grep -vc " fetch " "$S/out/git.log")" -eq 1 ] && grep -q -- "-c core.fsmonitor=false --no-optional-locks status" "$S/out/git.log"' "$(grep -vc ' fetch ' "$S/out/git.log") appel(s)"
: > "$S/out/git.log"; rendre "$S/sl/v3.sh" normal.json > /dev/null
verifie "rendu suivant dans les 5 s : aucun appel à git (cache)" '[ ! -s "$S/out/git.log" ]'
"$VRAI_GIT" -C "$S/proj/site" config core.fsmonitor "touch $TEMOIN"
rm -f "$(profil_cache)"/git-*; rendre "$S/sl/v3.sh" normal.json > /dev/null
verifie "commande déclarée par le dépôt (core.fsmonitor) : non exécutée" '[ ! -e "$TEMOIN" ]'
"$VRAI_GIT" -C "$S/proj/site" config --unset core.fsmonitor
if [ "$REF" = 1 ]; then
  rm -f "$(profil_cache)"/git-*; find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-git-*" -delete 2>/dev/null
  a=$(rendre "$S/sl/v3.sh" normal.json | texte | sed -n 2p); b=$(rendre "$S/sl/base.sh" normal.json | texte | sed -n 2p)
  verifie "même ligne git que la base" '[ "$a" = "$b" ]' "nouvelle : $a / base : $b"
fi

# ----------------------------------------------------------------------------
titre "12. Même affichage que la base"
# ----------------------------------------------------------------------------
if [ "$REF" = 1 ]; then
  normaliser() { texte | sed -E 's/[0-9]+h[0-9]+m/<durée>/g; s/[0-9]+j [0-9]+h/<durée>/g'; }
  perimer usage; chaud "$S/sl/v3.sh" normal.json usage > /dev/null
  find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-*" -delete 2>/dev/null; rendre "$S/sl/base.sh" normal.json > /dev/null
  ecarts=0; n=0
  while IFS= read -r filtre; do
    [ -n "$filtre" ] || continue
    n=$((n + 1)); entree "p$n.json" "$filtre"
    rendre "$S/sl/v3.sh" "p$n.json" | normaliser > "$S/out/p-nouvelle.txt"; rendre "$S/sl/base.sh" "p$n.json" | normaliser > "$S/out/p-base.txt"
    if ! cmp -s "$S/out/p-nouvelle.txt" "$S/out/p-base.txt"; then
      ecarts=$((ecarts + 1)); printf '         écart sur : %s\n' "$filtre"; diff "$S/out/p-base.txt" "$S/out/p-nouvelle.txt" | sed 's/^/           /' | head -6
    fi
  done <<'CAS'
.
.model.display_name = "Opus 5.5" | .effort.level = "low"
.model.display_name = "Opus 4.8" | .effort.level = "xhigh"
.model.display_name = "Sonnet 5.5" | .effort.level = "max" | .fast_mode = true
.model.display_name = "Sonnet 4.6" | .effort.level = "xhigh"
.model.display_name = "Sonnet 4.6" | .effort.level = "medium"
.model.display_name = "Haiku 5.5" | .effort.level = "medium"
.model.display_name = "Haiku 4.5" | del(.effort)
.model.display_name = "Mythos 5.2" | .effort.level = "ultra"
.model.display_name = "Modèle inconnu" | .effort.level = "high"
.agent = {name:"relecteur"} | .vim = {mode:"NORMAL"}
.vim = {mode:"INSERT"} | .fast_mode = true
.context_window.used_percentage = 0 | .cost.total_cost_usd = 0 | .cost.total_duration_ms = 900
.context_window.used_percentage = 74.6 | .cost.total_cost_usd = 12.345 | .cost.total_duration_ms = 3725000
.context_window.used_percentage = 95 | .cost.total_cost_usd = 0.000015
.context_window.used_percentage = 100.4
del(.workspace) | .cwd = "/usr/local"
CAS
  verifie "$n entrées types (modèles, efforts, fast, vim, agent, contexte, coûts) : affichage identique à la base" '[ "$ecarts" -eq 0 ]' "$ecarts écart(s)"
  entree racine.json '.workspace.current_dir = "/"'
  verifie "à la racine du disque, le projet s'affiche « / » (la base laissait un vide)" '[[ $(rendre "$S/sl/v3.sh" racine.json | texte | sed -n 1p) == "Fable 5.2 ▌▌▌▌▌ │ / │ v2.1.323 ●" ]]'
else
  printf '  note   branche main introuvable : comparaison avec la base sautée\n'
fi

# ----------------------------------------------------------------------------
titre "13. Mode serveur"
# ----------------------------------------------------------------------------
R="$S/racine"
printf '# réglages du banc\nSERVEUR="WEB-PROD"\nNIVEAU=critique\nDISQUES=/ /mnt/data\n' > "$R/etc/claude-statusline.conf"
printf '3.12 4.23 4.92 4/6134 3932627\n' > "$R/proc/loadavg"
printf 'MemTotal:       96545792 kB\nMemFree:         1000000 kB\nMemAvailable:   55657472 kB\nBuffers:         100 kB\nSwapCached:      100 kB\nSwapTotal:      16776188 kB\nSwapFree:       16257024 kB\n' > "$R/proc/meminfo"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=3056874376\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' > "$R/proc/pressure/memory"
printf '0-23\n' > "$R/sys/devices/system/cpu/online"
# Compteurs du processeur : 27 % d'activité depuis le relevé que semer_cpu pose dans le cache.
printf 'cpu  150000 0 77000 866000 7000 0 0 0 0 0\ncpu0 1 1 1 1 1 1 1 1 1 1\n' > "$R/proc/stat"
semer_cpu() { local P; P=$(profil_cache); [ -n "$P" ] && printf 'v3|%s|1000000|800000|\n' "$(( $(date +%s) - 10 ))" > "$P/cpu"; }
: > "$R/var/run/reboot-required"
printf '\n51 updates can be applied immediately.\n6 of these updates are standard security updates.\nTo see these additional updates run: apt list --upgradable\n' > "$R/var/lib/update-notifier/updates-available"
jq -n --arg d "$S/apps/site.fr" '[{name:"site-fr",pm2_env:{status:"online",restart_time:3,pm_cwd:$d,env:{DATABASE_URL:"SECRET-DE-L-APP-NE-DOIT-JAMAIS-SORTIR"}}},
  {name:"autre",pm2_env:{status:"online",restart_time:0,pm_cwd:"/var/www/apps/autre.fr",SECRET:"SECRET-DE-L-APP-NE-DOIT-JAMAIS-SORTIR"}},
  {name:"casse",pm2_env:{status:"errored",restart_time:15,pm_cwd:"/var/www/apps/casse.fr"}}]' > "$S/out/pm2-jlist.json"
mkdir -p "$HOME/.pm2"; printf '%s' "$$" > "$HOME/.pm2/pm2.pid"   # sans saut de ligne final, comme le vrai
python3 -I -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$HOME/.pm2/rpc.sock" 2>/dev/null \
  || ( cd "$HOME/.pm2" && python3 -I -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind("rpc.sock")' )
jq -cn --arg a "$S/apps/site.fr/src" '{model:{display_name:"Fable 5.2"},workspace:{current_dir:$a},version:"2.1.323",cost:{total_cost_usd:0.4,total_duration_ms:61000},context_window:{used_percentage:12},
  effort:{level:"medium"},session_id:"33333333-2222-3333-4444-555555555555",session_name:"certificat expiré",
  rate_limits:{five_hour:{used_percentage:23,resets_at:(now + 11520 | floor)},seven_day:{used_percentage:41,resets_at:(now + 460800 | floor)}}}' > "$S/out/srv.json"
vider_cache; : > "$S/out/git.log"; : > "$S/out/curl-argv.log"; : > "$S/out/curl-stdin.log"
COLUMNS=200 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null; attendre serveur; attendre usage; attendre statut
verifie "premier rendu : pas encore de CPU (il faut deux relevés), le reste s'affiche" 'L=$(COLUMNS=200 rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p); [[ $L != *CPU* && $L == *"RAM 42%"* ]]'
semer_cpu
COLUMNS=200 rendre "$S/sl/v3-serveur.sh" srv.json > "$S/out/srv.txt"; montrer < "$S/out/srv.txt"
T=$(texte < "$S/out/srv.txt"); L0=$(sed -n 1p <<< "$T")
verifie "trois lignes, la première est celle du serveur" '[ "$(wc -l < "$S/out/srv.txt")" -eq 3 ] && [[ $L0 == " WEB-PROD "* ]]' "$L0"
verifie "badge rouge pour un serveur critique" 'grep -q $'"'"'\033\[48;5;160m'"'"' "$S/out/srv.txt"'
verifie "processeur, mémoire et disques toujours affichés" '[[ $L0 == " WEB-PROD  │ CPU 27% │ RAM 42% │ disque 78% · data 41%"* && $L0 != *charge* ]]' "$L0"
verifie "PM2 : une app en erreur signalée" '[[ $L0 == *"PM2 2/3 · 1 en erreur"* ]]' "$L0"
verifie "build en cours (compté une fois, sans le shell qui le lance) et autres sessions Claude signalés" '[[ $L0 == *"1 build en cours"* && $L0 == *"2 sessions Claude"* ]]' "$L0"
verifie "redémarrage demandé et mises à jour en attente ne sont pas affichés (toujours vrais, donc muets)" '[[ $L0 != *màj* && $L0 != *redémarrage* ]]' "$L0"
verifie "sur un serveur : ni durée de session, ni montant en dollars, ni usage 5 h" '[[ $T != *"1m 1s"* && $T != *"\$"* && $T != *"5h "* ]]' "$(tr '\n' '/' <<< "$T")"
verifie "version de Claude Code et point de statut affichés, comme sur un poste" '[[ $(sed -n 2p <<< "$T") == *"│ v2.1.323 ●" ]]' "$(sed -n 2p <<< "$T")"
verifie "ligne 3 : contexte, quota 7 j, quota Fable et état de l'app sur une seule ligne" '[[ $(sed -n 3p <<< "$T") == "█░░░░░░░░░░░░░░ 12% │ 7j ▰▰▰▰▱▱▱▱▱▱ 41% 5j "*" │ Fable 14% │ pm2 ● en ligne ↺3" ]]' "$(sed -n 3p <<< "$T")"
verifie "le jeton part à l'API des quotas par l'entrée standard, jamais en argument" 'grep -q "oauth/usage" "$S/out/curl-argv.log" && ! grep -q "JETON" "$S/out/curl-argv.log" && grep -q "Bearer JETON" "$S/out/curl-stdin.log"'
verifie "sans montants à calculer, aucune transcription n'est lue" '[ -z "$(find "$CACHE" -name extraits)" ]' "$(find "$CACHE" -maxdepth 2 | sed "s#$CACHE/##" | tr '\n' ' ')"
verifie "le swap n'est pas affiché" '[[ $L0 != *swap* ]]'
verifie "ligne 1 : dossier avec son parent, nom de la session" '[[ $(sed -n 2p <<< "$T") == *"…/site.fr/src"*"certificat expiré"* ]]' "$(sed -n 2p <<< "$T")"
verifie "état PM2 de l'app où l'on se trouve" '[[ $(sed -n 3p <<< "$T") == *"pm2 ● en ligne ↺3"* ]]' "$(sed -n 3p <<< "$T")"
T72=$(COLUMNS=72 rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 3p)
verifie "à 72 colonnes la ligne 3 tient, en gardant le contexte, le 7 j et le quota Fable" '[ "${#T72}" -le 72 ] && [[ $T72 == *"12%"*"7j"*"41%"*"Fable 14%"* ]]' "$T72"
T44=$(COLUMNS=44 rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 3p)
verifie "à 44 colonnes il reste le contexte et le quota 7 j" '[ "${#T44}" -le 44 ] && [[ $T44 == *"12%"*"7j"*"41%"* ]]' "$T44"
verifie "l'environnement des apps (secrets de pm2 jlist) n'est écrit nulle part" '! grep -rq "SECRET-DE-L-APP" "$CACHE" "$S/out/srv.txt"'
verifie "aucun git fetch en mode serveur" '! grep -q " fetch " "$S/out/git.log"'
depasse=""
for c in 40 60 80 100 140; do
  COLUMNS=$c rendre "$S/sl/v3-serveur.sh" srv.json > "$S/out/s$c.txt"; w=$(largeur_max < "$S/out/s$c.txt"); [ "$w" -le "$c" ] || depasse+=" $c($w)"
  [ "$VERBEUX" = 1 ] && { printf '         --- %s colonnes ---\n' "$c"; montrer < "$S/out/s$c.txt"; }
done
verifie "ligne serveur de 40 à 140 colonnes : jamais plus large que le terminal" '[ -z "$depasse" ]' "dépassements :$depasse"
verifie "à 60 colonnes, l'app en erreur reste affichée" 'T6=$(texte < "$S/out/s60.txt" | sed -n 1p); [[ $T6 == *"en erreur"* ]]' "$(texte < "$S/out/s60.txt" | sed -n 1p)"
verifie "les alertes qui ne tiennent pas sont comptées en fin de ligne (« +N alertes »)" 'T6=$(texte < "$S/out/s60.txt" | sed -n 1p); T4=$(texte < "$S/out/s40.txt" | sed -n 1p); [[ $T6 =~ \+[0-9]+(\ alertes?)?$ && $T4 =~ \+[0-9]+(\ alertes?)?$ ]] && ! texte < "$S/out/s140.txt" | sed -n 1p | grep -qE "\+[0-9]+( alertes?)?$"' "60 : $(texte < "$S/out/s60.txt" | sed -n 1p) / 40 : $(texte < "$S/out/s40.txt" | sed -n 1p)"
printf '14.80 9.00 4.00 9/900 1\n' > "$R/proc/loadavg"; printf '0-7\n' > "$R/sys/devices/system/cpu/online"
printf 'MemTotal:       24020000 kB\nMemAvailable:    1200000 kB\nSwapTotal:       4193000 kB\nSwapFree:         308000 kB\n' > "$R/proc/meminfo"
printf 'some avg10=31.20 avg60=12.00 avg300=3.00 total=1\n' > "$R/proc/pressure/memory"
printf 'cpu  290000 0 7000 800000 3000 0 0 0 0 0\n' > "$R/proc/stat"
mkdir -p "$R/proc/4242"; ln -sf /var/www/apps/site.fr/src "$R/proc/4242/cwd"
printf '6500000 4242 next-server (v1\n' > "$S/out/ps-rss"
perimer serveur; chaud "$S/sl/v3-serveur.sh" srv.json serveur > /dev/null; semer_cpu
L0=$(COLUMNS=200 rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p)
verifie "serveur à bout de mémoire : CPU 97 %, RAM 95 % avec le nom et le poids du plus gros consommateur, pression mémoire" '[[ $L0 == *"CPU 97%"* && $L0 == *"RAM 95% · site.fr 6,1 Go"* && $L0 == *"pression mémoire 31%"* && $L0 != *swap* && $L0 != *charge* ]]' "$L0"
printf '900000 77 mariadbd\n' > "$S/out/ps-rss"; perimer serveur; chaud "$S/sl/v3-serveur.sh" srv.json serveur > /dev/null
L0=$(COLUMNS=200 rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p)
verifie "consommateur hors des apps : le nom du programme, en Mo sous 1 Go" '[[ $L0 == *"RAM 95% · mariadbd 878 Mo"* ]]' "$L0"
rm -f "$S/out/ps-rss"
printf 'SERVEUR=$(touch %s)\nROLE=`touch %s`\nNIVEAU=critique; touch %s\nDISQUES=/ $(touch %s)\n' "$TEMOIN" "$TEMOIN" "$TEMOIN" "$TEMOIN" > "$R/etc/claude-statusline.conf"
rendre "$S/sl/v3-serveur.sh" srv.json > "$S/out/conf.txt"; code=$?
verifie "réglages contenant des commandes : rien d'exécuté, valeurs refusées, barre normale à trois lignes" '[ "$code" = 0 ] && [ ! -e "$TEMOIN" ] && [ "$(wc -l < "$S/out/conf.txt")" -eq 3 ]'
printf 'SERVEUR=APP-PROD\nNIVEAU=prod\n' > "$R/etc/claude-statusline.conf"; mkdir -p "$HOME/.config"; printf 'SERVEUR=POSTE-DE-TEST\n' > "$HOME/.config/claude-statusline.conf"
L0=$(rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p)
verifie "le fichier de /etc fait foi : celui du dossier personnel ne peut pas renommer le serveur" '[[ $L0 == " APP-PROD "* ]]' "$L0"
L0=$(STATUSLINE_OPERATOR="alice" STATUSLINE_ACCOUNT="claude-2" rendre "$S/sl/v3-serveur.sh" srv.json | texte)
verifie "nom de l'opérateur et compte affichés quand ils sont transmis" '[[ $(sed -n 1p <<< "$L0") == " APP-PROD  alice"* && $(sed -n 3p <<< "$L0") == *"compte claude-2"* ]]' "$(sed -n 1p <<< "$L0") / $(sed -n 3p <<< "$L0")"
L0=$(STATUSLINE_OPERATOR=$'alice\033[31m;rm' rendre "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p)
verifie "nom de compte invalide : ignoré" '[[ $L0 != *alice* ]]' "$L0"
jq -c 'del(.rate_limits)' "$S/out/srv.json" > "$S/out/srv-debut.json"
T=$(rendre "$S/sl/v3-serveur.sh" srv-debut.json | texte | sed -n 3p)
verifie "avant que Claude Code transmette les quotas : le 7 j et le quota Fable viennent de l'API" '[[ $T == *" │ 7j ▰▰▰▰▱▱▱▱▱▱ 41% "*" │ Fable 14%"* ]]' "$T"
printf 'SERVEUR=APP-PROD\nNIVEAU=prod\nCOUTS=1\n' > "$R/etc/claude-statusline.conf"
T=$(rendre "$S/sl/v3-serveur.sh" srv.json | texte)
verifie "COUTS=1 rallume les montants en dollars" '[[ $(sed -n 3p <<< "$T") == *"\$0.40"* ]]' "$(sed -n 3p <<< "$T")"
printf 'SERVEUR=APP-PROD\nNIVEAU=prod\nQUOTA_API=0\nSTATUT_CLAUDE=0\n' > "$R/etc/claude-statusline.conf"
vider_cache; : > "$S/out/curl-argv.log"; : > "$S/out/curl-stdin.log"
rendre "$S/sl/v3-serveur.sh" srv-debut.json > /dev/null; attendre serveur; sleep 1
T=$(rendre "$S/sl/v3-serveur.sh" srv-debut.json | texte)
verifie "QUOTA_API=0 et STATUT_CLAUDE=0 : plus aucun appel réseau, aucun jeton lu, pas de ligne de quotas à 0 %" '[ ! -s "$S/out/curl-argv.log" ] && [ ! -s "$S/out/curl-stdin.log" ] && [ "$(wc -l <<< "$T")" -eq 3 ] && [[ $T != *"7j"* && $T != *"0%"*"--"* ]] && [[ $(sed -n 2p <<< "$T") == *"v2.1.323" ]]' "$(tr '\n' '/' <<< "$T")"
printf 'SERVEUR=APP-PROD\nNIVEAU=prod\n' > "$R/etc/claude-statusline.conf"; vider_cache
rm -f "$HOME/.pm2/rpc.sock"; perimer serveur; : > "$S/out/pm2.log"
printf '#!/bin/bash\necho appel >> "$BANC/out/pm2.log"\n' > "$S/bin/pm2"; chaud "$S/sl/v3-serveur.sh" srv.json serveur > /dev/null
verifie "pas de démon PM2 pour ce compte : pm2 n'est pas appelé (il en lancerait un)" '[ ! -s "$S/out/pm2.log" ]'

# ----------------------------------------------------------------------------
titre "14. Rafraîchissement en direct de la ligne du serveur (voie rapide)"
# ----------------------------------------------------------------------------
printf 'SERVEUR=WEB-PROD\nNIVEAU=critique\nDISQUES=/ /mnt/data\n' > "$R/etc/claude-statusline.conf"
printf 'MemTotal:       96545792 kB\nMemAvailable:   55657472 kB\n' > "$R/proc/meminfo"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' > "$R/proc/pressure/memory"
printf 'cpu  150000 0 77000 866000 7000 0 0 0 0 0\n' > "$R/proc/stat"
vider_cache; chaud "$S/sl/v3-serveur.sh" srv.json serveur > /dev/null; attendre usage; attendre statut
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > "$S/out/complet.txt"       # rendu complet : écrit la trame
semer_cpu; : > "$S/out/jq.log"; : > "$S/out/git.log"
COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv.json > "$S/out/rapide.txt"; code=$?
verifie "rien n'a changé : la ligne du serveur est recalculée sans jq ni git, les trois autres sont reprises telles quelles" '[ "$code" = 0 ] && [ ! -s "$S/out/jq.log" ] && [ ! -s "$S/out/git.log" ] && [ "$(sed 1d "$S/out/rapide.txt")" = "$(sed 1d "$S/out/complet.txt")" ] && [ "$(wc -l < "$S/out/rapide.txt")" -eq 3 ]' "jq : $(wc -l < "$S/out/jq.log" | tr -d ' ') appel(s)"
verifie "le processeur apparaît dès ce deuxième affichage" '[[ $(texte < "$S/out/rapide.txt" | sed -n 1p) == " WEB-PROD  │ CPU 27% │ RAM 42% │ disque 78% · data 41%"* ]]' "$(texte < "$S/out/rapide.txt" | sed -n 1p)"
printf 'MemTotal:       96545792 kB\nMemAvailable:   10000000 kB\n' > "$R/proc/meminfo"; : > "$S/out/jq.log"
L0=$(COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv.json | texte | sed -n 1p)
verifie "la mémoire change sur le serveur : la ligne suit à l'affichage suivant, toujours sans jq" '[[ $L0 == *"RAM 89%"* ]] && [ ! -s "$S/out/jq.log" ]' "$L0"
jq -c '.cost.total_duration_ms = 999999' "$S/out/srv.json" > "$S/out/srv-duree.json"; : > "$S/out/jq.log"
COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv-duree.json > /dev/null
verifie "seule la durée de session a avancé (cas d'un rafraîchissement par minuterie) : voie rapide" '[ ! -s "$S/out/jq.log" ]'
jq -c '.context_window.used_percentage = 77' "$S/out/srv.json" > "$S/out/srv-ctx.json"; : > "$S/out/jq.log"
T=$(COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv-ctx.json | texte | sed -n 3p)
verifie "le contexte a changé (nouvelle réponse de Claude) : rendu complet, la barre suit" '[ -s "$S/out/jq.log" ] && [[ $T == *"77%"* ]]' "$T"
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null; : > "$S/out/jq.log"
COLUMNS=90 enchainer "$S/sl/v3-serveur.sh" srv.json > /dev/null
verifie "la largeur du terminal a changé : rendu complet" '[ -s "$S/out/jq.log" ]'
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null
TR=$(find "$CACHE" -name 'trame-*' | head -1); sed -i.bak -E "1s/^v3\|[0-9]+/v3|$(( $(date +%s) - 60 ))/" "$TR" && rm -f "$TR.bak"; : > "$S/out/jq.log"
COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv.json > /dev/null
verifie "trame de plus de 15 secondes : rendu complet (les autres lignes ne vieillissent pas plus)" '[ -s "$S/out/jq.log" ]'
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null
TR=$(find "$CACHE" -name 'trame-*' | head -1)
python3 -I -c 'import sys; p = sys.argv[1]; l = open(p).read().split("\n"); l[2] = l[2] + "\x1b]0;VOISIN\x07\x1b[5;41m ALERTE"; open(p, "w").write("\n".join(l))' "$TR"; : > "$S/out/jq.log"
COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv.json > "$S/out/trame-inj.txt"
verifie "trame dont une ligne porte autre chose que des couleurs : refusée, rendu complet, rien d'injecté" '[ -s "$S/out/jq.log" ] && sans_sequence "$S/out/trame-inj.txt" && ! grep -q "VOISIN" "$S/out/trame-inj.txt"'
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null; sleep 1.1; touch "$(profil_cache)/statut"; : > "$S/out/jq.log"
COLUMNS=120 enchainer "$S/sl/v3-serveur.sh" srv.json > /dev/null
verifie "un cache d'arrière-plan vient d'être rafraîchi (statut, quotas, PM2) : rendu complet tout de suite" '[ -s "$S/out/jq.log" ]'
# Mesure : 20 affichages par la voie rapide, puis 20 rendus complets (la largeur change à chaque
# fois, ce qui écarte la voie rapide sans rien lancer de plus).
COLUMNS=120 rendre "$S/sl/v3-serveur.sh" srv.json > /dev/null
t0=$(horloge); for ((i = 0; i < 20; i++)); do COLUMNS=120 "$S/sl/v3-serveur.sh" < "$S/out/srv.json" > /dev/null 2>&1; done; t1=$(horloge)
for ((i = 0; i < 20; i++)); do COLUMNS=$((120 + i % 2)) "$S/sl/v3-serveur.sh" < "$S/out/srv.json" > /dev/null 2>&1; done; t2=$(horloge)
printf '  note   mode serveur : %s ms par affichage en voie rapide, %s ms par rendu complet (moyenne de 20)\n' \
  "$(python3 -I -c 'import sys; print(round((float(sys.argv[2]) - float(sys.argv[1])) * 50, 1))' "$t0" "$t1")" \
  "$(python3 -I -c 'import sys; print(round((float(sys.argv[2]) - float(sys.argv[1])) * 50, 1))' "$t1" "$t2")"
rm -f "$R/etc/claude-statusline.conf" "$HOME/.config/claude-statusline.conf"; vider_cache
chaud "$S/sl/v3.sh" normal.json usage > /dev/null; : > "$S/out/jq.log"; enchainer "$S/sl/v3.sh" normal.json > /dev/null
verifie "sur un poste : pas de voie rapide, pas de trame, rendu complet à chaque fois" '[ -s "$S/out/jq.log" ] && [ -z "$(find "$CACHE" -name "trame-*")" ]'
printf 'SERVEUR=APP-PROD\nNIVEAU=prod\n' > "$R/etc/claude-statusline.conf"

# ----------------------------------------------------------------------------
titre "15. Installation sur un serveur (dans un faux système de fichiers)"
# ----------------------------------------------------------------------------
I="$S/installe"; mkdir -p "$I/etc/claude-code"
printf '{"permissions":{"deny":["Read(./.env)"]},"statusLine":{"type":"command","command":"/ancien","padding":2}}' > "$I/etc/claude-code/managed-settings.json"
EMP=$(shasum -a 256 < "$S/sl/v3.sh" 2>/dev/null | cut -d' ' -f1 || sha256sum < "$S/sl/v3.sh" | cut -d' ' -f1)
inst() { "$BASH" "$REPO/serveur/installer.sh" --racine "$I" "$@" > "$S/out/inst.txt" 2>&1; }
inst --source "$S/sl/v3.sh" --empreinte "$EMP" --serveur WEB-PROD --niveau critique --disques "/ /mnt/data"; code=$?
verifie "sans --appliquer : le plan est affiché, rien n'est écrit" '[ "$code" = 0 ] && grep -q "À BLANC" "$S/out/inst.txt" && [ ! -e "$I/usr" ] && [ ! -e "$I/etc/claude-statusline.conf" ]'
inst --source "$S/sl/v3.sh" --empreinte "0000000000000000000000000000000000000000000000000000000000000000" --serveur WEB-PROD --appliquer; code=$?
verifie "empreinte différente de celle attendue : refus, rien n'est écrit" '[ "$code" != 0 ] && [ ! -e "$I/usr" ]'
inst --source "$S/sl/v3.sh" --empreinte "$EMP" --serveur 'X$(touch '"$TEMOIN"')' --appliquer; code=$?
verifie "nom de serveur contenant une commande : refus, rien d'exécuté" '[ "$code" != 0 ] && [ ! -e "$TEMOIN" ] && [ ! -e "$I/usr" ]'
mkdir -p "$I/usr/local/lib/claude-statusline"; chmod 750 "$I/usr/local/lib/claude-statusline"; chmod 750 "$I/etc/claude-code"
inst --source "$S/sl/v3.sh" --empreinte "$EMP" --serveur WEB-PROD --niveau critique --disques "/ /mnt/data" --sans-mise-en-service --appliquer; code=$?
verifie "--sans-mise-en-service : script et réglage posés, réglages de Claude Code intacts" '[ "$code" = 0 ] && [ -x "$I/usr/local/lib/claude-statusline/statusline.sh" ] && [ -f "$I/etc/claude-statusline.conf" ] && [ "$(jq -r .statusLine.command "$I/etc/claude-code/managed-settings.json")" = "/ancien" ]' "$(tail -2 "$S/out/inst.txt" | tr '\n' ' ')"
inst --source - --empreinte "$EMP" --serveur WEB-PROD --niveau critique --disques "/ /mnt/data" --appliquer < "$S/sl/v3.sh"; code=$?
[ "$VERBEUX" = 1 ] && sed 's/^/         | /' "$S/out/inst.txt"
droits=$(stat -c '%a' "$I/usr/local/lib/claude-statusline/statusline.sh" "$I/etc/claude-statusline.conf" 2>/dev/null | tr '\n' ' ' || true)
[ -n "$droits" ] || droits=$(stat -f '%Lp' "$I/usr/local/lib/claude-statusline/statusline.sh" "$I/etc/claude-statusline.conf" | tr '\n' ' ')
verifie "installation (script lu sur l'entrée standard) : script 755, réglage 644, rendu d'essai affiché" '[ "$code" = 0 ] && [ "$droits" = "755 644 " ] && grep -q "| Essai" "$S/out/inst.txt"' "code $code, droits $droits"
verifie "réglages gérés : statusLine posée, les autres clés et le padding conservés, copie datée faite" '[ "$(jq -c "[.statusLine.command, .statusLine.refreshInterval, .statusLine.padding, .permissions.deny[0]]" "$I/etc/claude-code/managed-settings.json")" = "[\"/usr/local/lib/claude-statusline/statusline.sh\",2,2,\"Read(./.env)\"]" ] && [ -n "$(find "$I/etc/claude-code" -name "managed-settings.json.avant-*")" ]' "$(jq -c . "$I/etc/claude-code/managed-settings.json")"
d1=$(stat -c '%a' "$I/usr/local/lib/claude-statusline" "$I/etc/claude-code" 2>/dev/null | tr '\n' ' ' || true); [ -n "$d1" ] || d1=$(stat -f '%Lp' "$I/usr/local/lib/claude-statusline" "$I/etc/claude-code" | tr '\n' ' ')
verifie "dossiers déjà là en 750 (masque strict de l'appelant) : remis en 755" '[ "$d1" = "755 755 " ]' "$d1"
verifie "le réglage écrit est celui que le script sait lire" 'grep -qx "SERVEUR=WEB-PROD" "$I/etc/claude-statusline.conf" && grep -qx "DISQUES=/ /mnt/data" "$I/etc/claude-statusline.conf"'
inst --source "$S/sl/v3.sh" --empreinte "$EMP" --serveur WEB-PROD --niveau critique --disques "/ /mnt/data" --appliquer
verifie "seconde installation identique : rien n'est réécrit" '[ "$(grep -c "déjà en place, identique" "$S/out/inst.txt")" -eq 2 ]'
inst --retirer --appliquer; code=$?
verifie "retrait : la clé statusLine part, le reste des réglages reste, les fichiers sont supprimés" '[ "$code" = 0 ] && [ "$(jq -c . "$I/etc/claude-code/managed-settings.json")" = "{\"permissions\":{\"deny\":[\"Read(./.env)\"]}}" ] && [ ! -e "$I/usr/local/lib/claude-statusline/statusline.sh" ] && [ ! -e "$I/etc/claude-statusline.conf" ]' "$(jq -c . "$I/etc/claude-code/managed-settings.json")"

# ----------------------------------------------------------------------------
titre "16. Vitesse"
# ----------------------------------------------------------------------------
vider_cache; rm -f "$R/etc/claude-statusline.conf" "$HOME/.config/claude-statusline.conf"; chaud "$S/sl/v3.sh" normal.json usage > /dev/null
mesure() { local t0 t1 i; t0=$(horloge); for ((i = 0; i < 20; i++)); do COLUMNS=120 "$1" < "$S/out/normal.json" > /dev/null 2>&1; done; t1=$(horloge)
  python3 -I -c 'import sys; print(int((float(sys.argv[2]) - float(sys.argv[1])) * 1000 / 20))' "$t0" "$t1"; }
m3=$(mesure "$S/sl/v3.sh")
if [ "$REF" = 1 ]; then rendre "$S/sl/base.sh" normal.json > /dev/null; mb=$(mesure "$S/sl/base.sh"); printf '  note   base : %s ms par rendu, nouvelle version : %s ms (caches chauds, moyenne de 20)\n' "$mb" "$m3"
else printf '  note   nouvelle version : %s ms par rendu\n' "$m3"; fi
verifie "un rendu à chaud prend moins de 60 ms" '[ "$m3" -lt 60 ]' "$m3 ms"

printf '\n%s essais réussis, %s en échec\n' "$N_OK" "$N_KO"
[ "$N_KO" -eq 0 ]
