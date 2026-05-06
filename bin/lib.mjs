// ============================================================================
// Helpers partages entre plateformes (log, color, exec, backup, hook).
// ============================================================================

import { execSync } from 'node:child_process';
import { copyFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline';

export const C = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  gray: '\x1b[90m',
};

export const log = {
  info: (m = '') => console.log(m),
  step: (m) => console.log(`${C.bold}${C.cyan}>${C.reset} ${m}`),
  ok: (m) => console.log(`  ${C.green}OK${C.reset}  ${m}`),
  warn: (m) => console.log(`  ${C.yellow}!!${C.reset}  ${m}`),
  err: (m) => console.error(`  ${C.red}XX${C.reset}  ${m}`),
  title: (m) =>
    console.log(`\n${C.bold}${C.magenta}=== ${m} ===${C.reset}\n`),
};

export function has(cmd) {
  try {
    execSync(`command -v ${cmd}`, { stdio: 'pipe', shell: '/bin/bash' });
    return true;
  } catch {
    return false;
  }
}

export function backup(path) {
  if (!existsSync(path)) return null;
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const dst = `${path}.${ts}.bak`;
  copyFileSync(path, dst);
  return dst;
}

export function cmdOutput(cmd) {
  try {
    return execSync(cmd, { stdio: ['ignore', 'pipe', 'pipe'] })
      .toString()
      .trim();
  } catch {
    return '';
  }
}

// ============================================================================
// Hook UserPromptSubmit "git fetch" — gestion idempotente
// ============================================================================
// Le hook lance un "git fetch --quiet --no-tags" detache en background a chaque
// message envoye, pour que la statusline affiche un ↓N a jour. Optionnel,
// propose lors de l'install via prompt TTY.
//
// Note POSIX : on utilise ">/dev/null 2>&1 &" et NON "& disown". Claude Code
// execute les hooks via /bin/sh, qui sur Debian/Ubuntu/WSL2 est un lien vers
// dash — dash n'a pas le builtin "disown" (specifique a bash/zsh). La
// redirection des 3 FDs + & suffit a detacher le subprocess sans SIGHUP.
// ============================================================================

// Marqueur shell unique pour identifier notre hook lors des re-installs et
// uninstalls. Le "#" en fait un commentaire bash inerte.
export const FETCH_HOOK_MARKER = '# scc-fetch-hook';

export const FETCH_HOOK_COMMAND =
  '(cd "$CLAUDE_PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1 && ' +
  "git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && " +
  'git fetch --quiet --no-tags 2>/dev/null) </dev/null >/dev/null 2>&1 & ' +
  FETCH_HOOK_MARKER;

// Detection : matche le marqueur exact OU une signature heuristique (retro-
// compat pour les anciennes installs sans marqueur, y compris les versions
// "& disown" pre-migration POSIX).
function _isOurHookCommand(cmd) {
  if (typeof cmd !== 'string') return false;
  if (cmd.includes(FETCH_HOOK_MARKER)) return true;
  return cmd.includes('git fetch --quiet --no-tags') && cmd.includes('CLAUDE_PROJECT_DIR');
}

export function hasFetchHook(settingsJson) {
  const hooks = settingsJson?.hooks?.UserPromptSubmit;
  if (!Array.isArray(hooks)) return false;
  for (const matcher of hooks) {
    const inner = matcher?.hooks;
    if (!Array.isArray(inner)) continue;
    if (inner.some((h) => _isOurHookCommand(h?.command))) return true;
  }
  return false;
}

// Retourne true UNIQUEMENT si la commande installee est exactement la version
// courante. Utilise par l'installeur pour detecter une vieille install (ex:
// "& disown") qu'il faut migrer.
export function isLatestFetchHook(settingsJson) {
  const hooks = settingsJson?.hooks?.UserPromptSubmit;
  if (!Array.isArray(hooks)) return false;
  for (const matcher of hooks) {
    const inner = matcher?.hooks;
    if (!Array.isArray(inner)) continue;
    if (inner.some((h) => h?.command === FETCH_HOOK_COMMAND)) return true;
  }
  return false;
}

export function addFetchHook(settingsJson) {
  if (hasFetchHook(settingsJson)) return false;
  if (!settingsJson.hooks) settingsJson.hooks = {};
  if (!Array.isArray(settingsJson.hooks.UserPromptSubmit)) settingsJson.hooks.UserPromptSubmit = [];
  settingsJson.hooks.UserPromptSubmit.push({
    hooks: [{ type: 'command', command: FETCH_HOOK_COMMAND }],
  });
  return true;
}

// Migre une install existante vers la version courante de la commande.
// Retourne true si une migration a eu lieu, false sinon.
export function migrateFetchHook(settingsJson) {
  if (!hasFetchHook(settingsJson)) return false;
  if (isLatestFetchHook(settingsJson)) return false;
  removeFetchHook(settingsJson);
  addFetchHook(settingsJson);
  return true;
}

// Retire UNIQUEMENT notre hook, preserve les autres hooks UserPromptSubmit.
// Nettoie les structures vides (UserPromptSubmit: [], hooks: {}) pour ne pas
// laisser de cles vides dans settings.json.
export function removeFetchHook(settingsJson) {
  const hooks = settingsJson?.hooks?.UserPromptSubmit;
  if (!Array.isArray(hooks)) return false;
  let removed = false;
  const filtered = [];
  for (const matcher of hooks) {
    const inner = matcher?.hooks;
    if (!Array.isArray(inner)) {
      filtered.push(matcher);
      continue;
    }
    const innerKept = inner.filter((h) => {
      if (_isOurHookCommand(h?.command)) {
        removed = true;
        return false;
      }
      return true;
    });
    if (innerKept.length > 0) filtered.push({ ...matcher, hooks: innerKept });
  }
  if (!removed) return false;
  if (filtered.length > 0) {
    settingsJson.hooks.UserPromptSubmit = filtered;
  } else {
    delete settingsJson.hooks.UserPromptSubmit;
    if (Object.keys(settingsJson.hooks).length === 0) delete settingsJson.hooks;
  }
  return true;
}

// Prompt TTY Y/N. Retourne null si pas de TTY (CI / pipe / non-interactif),
// pour que l'appelant puisse afficher un fallback explicite.
export async function promptYesNo(question, defaultYes = false) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) return null;
  const suffix = defaultYes ? '[Y/n]' : '[y/N]';
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} ${suffix} `, (answer) => {
      rl.close();
      const a = answer.trim().toLowerCase();
      if (a === '') resolve(defaultYes);
      else if (a === 'y' || a === 'yes' || a === 'o' || a === 'oui') resolve(true);
      else resolve(false);
    });
  });
}
