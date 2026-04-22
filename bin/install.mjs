#!/usr/bin/env node
// ============================================================================
// Claude Code Statusline - Installer cross-platform
// Entry point : detecte l'OS et dispatch vers le bon installeur.
// ============================================================================

import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { log, C } from './lib.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const STATUSLINE_SRC = resolve(ROOT, 'statusline.sh');

const HELP = `
${C.bold}statusline-claude-code${C.reset} - Installer cross-platform

${C.bold}Usage:${C.reset}
  npx github:jeremywtp/statusline-claude-code [commande] [options]

${C.bold}Commandes:${C.reset}
  install      Installe la statusline (defaut)
  uninstall    Retire la statusline et la cle statusLine
  doctor       Diagnostique l'install et les dependances
  help         Affiche cette aide

${C.bold}Options:${C.reset}
  --no-backup  N'ecrit pas de .bak des fichiers modifies

${C.bold}OS supportes:${C.reset}
  ${C.green}Linux${C.reset}   natif ou WSL2         -- installation directe
  ${C.green}macOS${C.reset}   Intel + Apple Silicon -- installation + patch GNU via Homebrew
  ${C.yellow}Windows${C.reset} natif                 -- non supporte, utiliser WSL2
`;

function detectPlatform() {
  if (process.platform === 'darwin') return 'macos';
  if (process.platform === 'linux') return 'linux';
  if (process.platform === 'win32') return 'windows';
  return null;
}

async function main() {
  const args = process.argv.slice(2);
  const cmd = args.find((a) => !a.startsWith('-')) || 'install';
  const flags = {
    noBackup: args.includes('--no-backup'),
  };

  if (['help', '--help', '-h'].includes(cmd)) {
    console.log(HELP);
    return;
  }

  if (!['install', 'uninstall', 'doctor'].includes(cmd)) {
    log.err(`Commande inconnue : ${cmd}`);
    console.log(HELP);
    process.exit(1);
  }

  if (cmd !== 'uninstall' && !existsSync(STATUSLINE_SRC)) {
    log.err(`statusline.sh introuvable dans le package (${STATUSLINE_SRC})`);
    process.exit(1);
  }

  const platform = detectPlatform();
  if (!platform) {
    log.err(`OS non supporte : ${process.platform}`);
    process.exit(1);
  }

  log.title(`statusline-claude-code - ${cmd} (${platform})`);

  try {
    const mod = await import(`./platforms/${platform}.mjs`);
    const fn = mod[cmd];
    if (typeof fn !== 'function') {
      log.err(`Commande ${cmd} non implementee pour ${platform}`);
      process.exit(1);
    }
    await fn({ statuslineSrc: STATUSLINE_SRC, flags });
  } catch (e) {
    log.err(`Echec : ${e.message}`);
    if (process.env.DEBUG) console.error(e);
    process.exit(1);
  }
}

main();
