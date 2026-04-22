# -- BEGIN macOS compat shim ----------------------------------------------
# Installe par statusline-claude-code (npx github:jeremywtp/statusline-claude-code).
# Remplace les commandes GNU (stat, date, find, md5sum, grep, flock) par
# leurs equivalents Homebrew (gstat, gdate, gfind, gmd5sum, ggrep) sur macOS.
# PAS de $(brew --prefix) : brew n'est pas toujours dans le PATH quand
# Claude Code execute ce script (PATH minimal).
if [[ "$(uname)" == "Darwin" ]]; then
  if [[ -x "/opt/homebrew/bin/gstat" ]]; then
    _GNU="/opt/homebrew/bin"      # Apple Silicon (M1/M2/M3/M4)
  elif [[ -x "/usr/local/bin/gstat" ]]; then
    _GNU="/usr/local/bin"         # Intel Mac
  else
    echo "statusline: GNU coreutils introuvables. brew install coreutils findutils grep" >&2
    exit 1
  fi
  stat()   { "$_GNU/gstat"   "$@"; }
  date()   { "$_GNU/gdate"   "$@"; }
  md5sum() { "$_GNU/gmd5sum" "$@"; }
  grep()   { "$_GNU/ggrep"   "$@"; }
  if [[ -x "$_GNU/gfind" ]]; then
    find() { "$_GNU/gfind" "$@"; }
  fi
  flock() { return 0; }
  export -f stat date find md5sum grep flock 2>/dev/null
fi
# -- END macOS compat shim ------------------------------------------------
