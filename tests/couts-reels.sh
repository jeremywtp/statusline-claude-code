#!/usr/bin/env bash
# ============================================================================
# Compare les coûts 5 h / 7 j de la base (branche main) et de la version courante sur de
# VRAIES transcriptions, sans rien toucher au vrai profil : profil d'essai dont `projects`
# est un lien vers le dossier donné, faux curl (fenêtre 7 j finissant dans 2 jours, fenêtre
# 5 h finissant dans 2 heures), aucun appel réseau. Lecture seule sur les transcriptions.
#
# Usage : tests/couts-reels.sh [dossier projects]     (défaut : ~/.claude/projects)
# ============================================================================
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && exec "$b" "$0" "$@"; done
  echo "bash 4 ou plus récent est requis" >&2; exit 2
fi
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJETS="${1:-$HOME/.claude/projects}"
[ -d "$PROJETS/" ] || { echo "dossier introuvable : $PROJETS" >&2; exit 2; }
S=$(mktemp -d "${TMPDIR:-/tmp}/sl-essais.XXXXXX") || exit 2
S=$(cd "$S" && pwd -P)
VRAI_GIT=$(command -v git); UID_NUM=$(id -u)
nettoyer() {
  [ -n "${HASH_PROFIL:-}" ] && find /tmp/ -maxdepth 1 -name "claude-sl-${UID_NUM}-${HASH_PROFIL}-*" -delete 2>/dev/null
  [ -n "$S" ] && [ -d "$S" ] && [[ $S == */sl-essais.* ]] && rm -rf -- "$S"
}
trap nettoyer EXIT

mkdir -p "$S/bin" "$S/home/.claude" "$S/sl" "$S/out"
ln -s "$PROJETS" "$S/home/.claude/projects"
printf '{"claudeAiOauth":{"accessToken":"JETON-FICHIER-FACTICE-0000000000"}}' > "$S/home/.claude/.credentials.json"
MAINTENANT=$(date +%s)
iso() { python3 -I -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
printf '{"five_hour":{"utilization":10,"resets_at":"%s"},"seven_day":{"utilization":20,"resets_at":"%s"}}' "$(iso $((MAINTENANT + 7200)))" "$(iso $((MAINTENANT + 172800)))" > "$S/out/api-corps"
cat > "$S/bin/curl" <<'FAUX'
#!/bin/bash
out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
cat > /dev/null 2>&1 < /dev/stdin &
case "$*" in
  *oauth/usage*) if [ -n "$out" ]; then cat "$BANC/out/api-corps" > "$out"; printf 200; else cat "$BANC/out/api-corps"; fi ;;
  *) exit 22 ;;
esac
FAUX
chmod +x "$S/bin/curl"
python3 -I "$REPO/tests/monter.py" "$REPO" "$REPO/statusline.sh" "$S/sl/v3.sh" > /dev/null || exit 2
"$VRAI_GIT" -C "$REPO" show main:statusline.sh > "$S/sl/base-source.sh" || { echo "branche main introuvable" >&2; exit 2; }
python3 -I "$REPO/tests/monter.py" "$REPO" "$S/sl/base-source.sh" "$S/sl/base.sh" > /dev/null || exit 2

find "$PROJETS/" -name '*.jsonl' -mtime -7 -print0 2>/dev/null | xargs -0 stat -f '%z' 2>/dev/null | awk '{ n++; s += $1 } END { printf "transcriptions de moins de 7 jours : %d fichiers, %.0f Mo\n", n, s / 1048576 }' \
  || find "$PROJETS/" -name '*.jsonl' -mtime -7 -printf '%s\n' | awk '{ n++; s += $1 } END { printf "transcriptions de moins de 7 jours : %d fichiers, %.0f Mo\n", n, s / 1048576 }'

export BANC="$S" HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" PATH="$S/bin:$PATH"
unset XDG_CACHE_HOME CLAUDE_CODE_OAUTH_TOKEN COLUMNS
if command -v sha256sum >/dev/null 2>&1; then HASH_PROFIL=$(printf '%s' "$CLAUDE_CONFIG_DIR" | sha256sum | cut -c1-8)
else HASH_PROFIL=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8); fi
ENTREE='{"model":{"display_name":"Fable 5.2"},"workspace":{"current_dir":"/"},"version":"2.1.323","session_id":"99999999-0000-0000-0000-000000000000"}'
texte() { sed $'s/\033\\[[0-9;]*m//g'; }
horloge() { python3 -I -c 'import time; print(time.time())'; }
duree() { python3 -I -c 'import sys; print("%.1f s" % (float(sys.argv[2]) - float(sys.argv[1])))' "$1" "$2"; }
CACHE="$HOME/.cache/claude-statusline"
attendre() {
  local i f v e reste
  for ((i = 0; i < 1200; i++)); do
    f=$(find "$CACHE" -name usage 2>/dev/null | head -1)
    if [ -n "$f" ] && [ -z "$(find "$CACHE" -name 'verrou.d' 2>/dev/null)" ]; then IFS='|' read -r v e reste < "$f"; [ "${e:-0}" -ge "$1" ] && return 0; fi
    sleep 0.25
  done
  return 1
}

t0=$(horloge); B=$(printf '%s' "$ENTREE" | "$S/sl/base.sh" 2>/dev/null | texte | sed -n 3p); t1=$(horloge)
echo "base     : $B"
echo "           rendu bloqué pendant $(duree "$t0" "$t1") (calcul dans le rendu)"
t0=$(horloge); printf '%s' "$ENTREE" | "$S/sl/v3.sh" > /dev/null 2>&1; t1=$(horloge); attendre "$MAINTENANT"; t2=$(horloge)
N=$(printf '%s' "$ENTREE" | "$S/sl/v3.sh" 2>/dev/null | texte | sed -n 3p)
echo "nouvelle : $N"
echo "           rendu en $(duree "$t0" "$t1"), premier calcul en arrière-plan : $(duree "$t1" "$t2")"
f=$(find "$CACHE" -name usage | head -1); sed -i.bak -E 's/^v3\|[0-9]+/v3|1/' "$f" && rm -f "$f.bak"
t0=$(horloge); printf '%s' "$ENTREE" | "$S/sl/v3.sh" > /dev/null 2>&1; attendre "$(date +%s)"; t1=$(horloge)
echo "           calcul suivant (seules les sessions modifiées sont relues) : $(duree "$t0" "$t1")"
cb=$(grep -oE '\$[0-9]+\.[0-9]{2}' <<< "$B" | tr '\n' ' '); cn=$(grep -oE '\$[0-9]+\.[0-9]{2}' <<< "$N" | tr '\n' ' ')
if [ "$cb" = "$cn" ] && [ -n "$cb" ]; then echo "RÉSULTAT : coûts identiques ($cn)"; else echo "RÉSULTAT : ÉCART — base $cb / nouvelle $cn"; exit 1; fi
