#!/usr/bin/env bash
# ============================================================================
# Installe la statusline sur un SERVEUR, sans npx ni accès à GitHub depuis le serveur.
#
#   script   : /usr/local/lib/claude-statusline/statusline.sh   (root, 755)
#   réglage  : /etc/claude-statusline.conf                      (root, 644)
#   mise en service, au choix :
#     --portee tous    /etc/claude-code/managed-settings.json : tous les comptes de la machine,
#                      sans qu'un fichier d'un dossier personnel puisse la remplacer (défaut)
#     --portee compte  ~/.claude/settings.json du compte qui lance l'installation
#
# Par défaut l'installeur ne fait RIEN : il montre ce qu'il ferait. Ajouter --appliquer pour
# écrire. Chaque fichier remplacé est d'abord copié à côté, avec la date.
# Le script installé doit avoir l'empreinte attendue (--empreinte) : on installe ce qui a été
# relu, pas ce qui est arrivé. « --source - » lit le script sur l'entrée standard (rien n'est
# déposé dans /tmp).
#
# Usage :
#   installer.sh --source statusline.sh --empreinte <sha256> --serveur NOM \
#                [--niveau critique|prod|outils|secours] [--disques "/ /mnt/data"] \
#                [--portee tous|compte] [--intervalle 2] [--sans-mise-en-service] [--appliquer]
#   (--sans-mise-en-service : pose le script et son réglage sans toucher aux réglages de Claude
#    Code, pour l'essayer à la main avant de le mettre en service par un second passage)
#   installer.sh --retirer [--portee tous|compte] [--appliquer]
# ============================================================================
set -euo pipefail
umask 022

SOURCE=""; EMPREINTE=""; SERVEUR=""; NIVEAU=""; DISQUES="/"; PORTEE="tous"; INTERVALLE=2
APPLIQUER=0; RETIRER=0; RACINE=""; SERVICE=1
while [ $# -gt 0 ]; do
  case $1 in
    --source) SOURCE=$2; shift 2 ;;
    --empreinte) EMPREINTE=$2; shift 2 ;;
    --serveur) SERVEUR=$2; shift 2 ;;
    --niveau) NIVEAU=$2; shift 2 ;;
    --disques) DISQUES=$2; shift 2 ;;
    --portee) PORTEE=$2; shift 2 ;;
    --intervalle) INTERVALLE=$2; shift 2 ;;
    --appliquer) APPLIQUER=1; shift ;;
    --sans-mise-en-service) SERVICE=0; shift ;;
    --retirer) RETIRER=1; shift ;;
    --racine) RACINE=$2; shift 2 ;;      # banc d'essai : tout est écrit sous ce dossier
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 2 ;;
  esac
done

dire() { printf '%s\n' "$*"; }
refuser() { printf 'REFUS : %s\n' "$*" >&2; exit 1; }
# Même règle que la lecture du réglage par statusline.sh : ASCII imprimable sans caractère de
# commande, 60 caractères au plus. Une valeur que le script ignorerait est refusée ici.
valide() { [[ $1 =~ ^[A-Za-z0-9\ ._,:/+@%-]{0,60}$ ]]; }
empreinte_de() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

case $PORTEE in tous|compte) ;; *) refuser "--portee vaut « tous » ou « compte »" ;; esac
[[ $INTERVALLE =~ ^[1-9][0-9]{0,2}$ ]] || refuser "--intervalle : nombre de secondes entre 1 et 999"
command -v jq >/dev/null 2>&1 || refuser "jq est absent de ce serveur (la statusline en a besoin)"
[ "${BASH_VERSINFO[0]}" -ge 5 ] || refuser "bash 5 ou plus récent est requis (ici ${BASH_VERSION})"

DEST_DIR="$RACINE/usr/local/lib/claude-statusline"
DEST="$DEST_DIR/statusline.sh"
CONF="$RACINE/etc/claude-statusline.conf"
if [ "$PORTEE" = tous ]; then REGLAGES="$RACINE/etc/claude-code/managed-settings.json"
else REGLAGES="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; fi
COMMANDE="/usr/local/lib/claude-statusline/statusline.sh"
DATE=$(date +%Y%m%d-%H%M%S)

if [ -z "$RACINE" ] && [ "$APPLIQUER" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  refuser "à lancer en root (sudo) : le script et son réglage appartiennent à root"
fi

sauvegarder() {  # copie datée, à côté, droits conservés
  [ -e "$1" ] || return 0
  cp -p "$1" "$1.avant-$DATE"
  dire "  copie : $1.avant-$DATE"
}
ecrire_json() {  # ecrire_json <fichier> <filtre jq> : fusion, sans toucher aux autres clés
  local f=$1 filtre=$2 tmp
  mkdir -p "$(dirname "$f")"
  tmp="$f.nouveau-$$"
  if [ -e "$f" ]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || refuser "$f n'est pas un objet JSON lisible : rien n'est modifié"
    sauvegarder "$f"
    jq "$filtre" "$f" > "$tmp"
    # cat > : le fichier garde son propriétaire, ses droits et son inode.
    cat "$tmp" > "$f"; rm -f "$tmp"
  else
    jq -n "{} | $filtre" > "$tmp"
    chmod 644 "$tmp"; mv "$tmp" "$f"
  fi
}

# ----------------------------------------------------------------------------
if [ "$RETIRER" = 1 ]; then
  dire "Retrait de la statusline ($PORTEE)"
  dire "  $REGLAGES : retirer la clé statusLine"
  dire "  $DEST, $CONF : supprimer"
  [ "$APPLIQUER" = 1 ] || { dire "À BLANC : rien n'a été modifié. Ajouter --appliquer."; exit 0; }
  [ -e "$REGLAGES" ] && ecrire_json "$REGLAGES" 'del(.statusLine)'
  rm -f "$DEST" "$CONF"
  rmdir "$DEST_DIR" 2>/dev/null || true
  dire "Retiré. Les sessions ouvertes le voient au prochain rendu ; le cache de chaque compte (~/.cache/claude-statusline) peut être supprimé."
  exit 0
fi

# ----------------------------------------------------------------------------
[ -n "$SOURCE" ] || refuser "--source manque"
[ -n "$SERVEUR" ] || refuser "--serveur manque (le nom affiché dans le badge)"
if [ "$SOURCE" = "-" ]; then CONTENU=$(cat); else [ -r "$SOURCE" ] || refuser "source illisible : $SOURCE"; CONTENU=$(cat "$SOURCE"); fi
RECUE=$(printf '%s\n' "$CONTENU" | empreinte_de)
[ -n "$EMPREINTE" ] || refuser "--empreinte manque. Empreinte du script reçu : $RECUE"
[ "$RECUE" = "$EMPREINTE" ] || refuser "empreinte différente de celle attendue (reçue : $RECUE)"
# (comparaison par motif, sans tube : sous « pipefail », un grep -q qui s'arrête au premier
# résultat fait échouer la commande qui l'alimente)
[[ $CONTENU == *$'\nset -euo pipefail\n'* ]] || refuser "ce fichier n'est pas statusline.sh"
printf '%s\n' "$CONTENU" | bash -n || refuser "le script reçu ne passe pas la vérification de syntaxe de ce bash"
for v in "$SERVEUR" "$DISQUES"; do valide "$v" || refuser "valeur refusée (caractères ou longueur) : $v"; done
case $NIVEAU in ''|critique|prod|outils|secours) ;; *) refuser "--niveau : critique, prod, outils ou secours" ;; esac
for m in $DISQUES; do [[ $m == /* ]] || refuser "--disques : des points de montage absolus, séparés par des espaces"; done

REGLAGE=$(printf '# Statusline Claude Code : nom et surveillance de ce serveur. Lu, jamais exécuté.\nSERVEUR=%s\nNIVEAU=%s\nDISQUES=%s\n' "$SERVEUR" "$NIVEAU" "$DISQUES")
FILTRE=".statusLine = {type: \"command\", command: \"$COMMANDE\", padding: ((.statusLine.padding // 1)), refreshInterval: $INTERVALLE}"

dire "Installation de la statusline sur « $SERVEUR » (portée : $PORTEE)"
dire "  script   : $DEST  (empreinte $RECUE)"
if [ -e "$DEST" ]; then dire "             remplace un script d'empreinte $(empreinte_de < "$DEST")"; fi
dire "  réglage  : $CONF"
printf '%s\n' "$REGLAGE" | sed -n '2,$p' | sed 's/^/             /'
if [ "$SERVICE" = 1 ]; then
  dire "  service  : $REGLAGES"
  if [ -e "$REGLAGES" ]; then dire "             statusLine actuelle : $(jq -c '.statusLine // "aucune"' "$REGLAGES" 2>/dev/null)"; fi
  dire "             statusLine posée    : {\"type\":\"command\",\"command\":\"$COMMANDE\",\"refreshInterval\":$INTERVALLE}"
else
  dire "  service  : non modifié (--sans-mise-en-service) : aucune session ne l'utilise encore"
fi
[ "$APPLIQUER" = 1 ] || { dire "À BLANC : rien n'a été modifié. Ajouter --appliquer."; exit 0; }

mkdir -p "$DEST_DIR"
# Droits fixés ici, pas hérités : un dossier créé plus tôt par sudo sous un masque strict (0007
# sur certains serveurs) sort en 750, et le script devient introuvable pour les comptes ordinaires.
chmod 755 "$DEST_DIR"
if [ -e "$DEST" ] && [ "$(empreinte_de < "$DEST")" = "$RECUE" ]; then
  dire "  script déjà en place, identique"
else
  sauvegarder "$DEST"
  printf '%s\n' "$CONTENU" > "$DEST.nouveau-$$"
  chmod 755 "$DEST.nouveau-$$"
  mv -f "$DEST.nouveau-$$" "$DEST"
fi
if [ -e "$CONF" ] && [ "$(cat "$CONF")" = "$REGLAGE" ]; then
  dire "  réglage déjà en place, identique"
else
  sauvegarder "$CONF"
  mkdir -p "$(dirname "$CONF")"
  printf '%s\n' "$REGLAGE" > "$CONF.nouveau-$$"
  chmod 644 "$CONF.nouveau-$$"
  mv -f "$CONF.nouveau-$$" "$CONF"
fi
if [ "$SERVICE" = 1 ]; then
  ecrire_json "$REGLAGES" "$FILTRE"
  if [ "$PORTEE" = tous ]; then chmod 755 "$(dirname "$REGLAGES")"; chmod 644 "$REGLAGES"; fi
fi
if [ -z "$RACINE" ]; then
  chown root:root "$DEST_DIR" "$DEST" "$CONF"
  if [ "$SERVICE" = 1 ] && [ "$PORTEE" = tous ]; then chown root:root "$REGLAGES"; fi
fi

# Preuve : un rendu, sans cache (HOME introuvable), avec le script qui vient d'être posé.
# Jamais en root : root pourrait créer ce dossier introuvable, et un script d'affichage n'a pas
# à tourner avec ses droits. Le rendu se fait sous le compte qui a lancé sudo, sinon « nobody ».
dire "Rendu d'essai :"
JSON_ESSAI='{"model":{"display_name":"Essai"},"workspace":{"current_dir":"/"},"version":"0","context_window":{"used_percentage":0}}'
if [ "$(id -u)" -eq 0 ]; then
  COMPTE_ESSAI=${SUDO_USER:-nobody}
  [ "$COMPTE_ESSAI" = root ] && COMPTE_ESSAI=nobody
  ESSAI=$(printf '%s' "$JSON_ESSAI" | runuser -u "$COMPTE_ESSAI" -- env HOME=/nonexistent COLUMNS=120 "$DEST" 2>&1) || true
else
  ESSAI=$(printf '%s' "$JSON_ESSAI" | HOME=/nonexistent COLUMNS=120 "$DEST" 2>&1) || true
fi
if [ -n "$ESSAI" ]; then printf '%s\n' "$ESSAI" | sed $'s/\033\\[[0-9;]*m//g; s/^/  | /'
else dire "  ATTENTION : le rendu d'essai n'a rien affiché. Vérifier avant de fermer la session."; fi
if [ "$SERVICE" = 1 ]; then dire "Installé. Les sessions Claude ouvertes prennent le réglage au prochain rendu."
else dire "Posé, pas en service. Relancer sans --sans-mise-en-service pour le mettre en service."; fi
dire "Retour arrière : $0 --retirer --portee $PORTEE --appliquer  (ou remettre les copies « .avant-$DATE »)"
