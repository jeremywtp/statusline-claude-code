// ============================================================================
// Linux / WSL2 - installer natif
// ============================================================================

import { execSync } from 'node:child_process';
import {
  copyFileSync,
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  chmodSync,
  unlinkSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { log, C, has, backup, cmdOutput } from '../lib.mjs';

const CLAUDE_DIR = join(homedir(), '.claude');
const STATUSLINE_DST = join(CLAUDE_DIR, 'statusline.sh');
const SETTINGS = join(CLAUDE_DIR, 'settings.json');

function detectWsl() {
  try {
    return readFileSync('/proc/version', 'utf8')
      .toLowerCase()
      .includes('microsoft');
  } catch {
    return false;
  }
}

function mergeSettings() {
  let json = {};
  if (existsSync(SETTINGS)) {
    try {
      json = JSON.parse(readFileSync(SETTINGS, 'utf8'));
    } catch (e) {
      throw new Error(`settings.json illisible : ${e.message}`);
    }
  }
  json.statusLine = {
    type: 'command',
    command: '~/.claude/statusline.sh',
    padding: 1,
  };
  writeFileSync(SETTINGS, JSON.stringify(json, null, 2) + '\n');
}

export async function install({ statuslineSrc, flags }) {
  const wsl = detectWsl();
  log.info(`Environnement : ${wsl ? 'WSL2' : 'Linux natif'}\n`);

  log.step('Verification des dependances');
  const deps = ['jq', 'curl', 'git'];
  const missing = deps.filter((d) => !has(d));
  if (missing.length) {
    log.err(`Dependances manquantes : ${missing.join(', ')}`);
    log.info('');
    log.info(`  ${C.dim}Ubuntu/Debian${C.reset} : sudo apt install -y ${missing.join(' ')}`);
    log.info(`  ${C.dim}Arch/Manjaro${C.reset}  : sudo pacman -S ${missing.join(' ')}`);
    log.info(`  ${C.dim}Fedora${C.reset}        : sudo dnf install -y ${missing.join(' ')}`);
    log.info('');
    process.exit(1);
  }
  deps.forEach((d) => log.ok(d));

  log.step('\nPreparation de ~/.claude/');
  if (!existsSync(CLAUDE_DIR)) {
    mkdirSync(CLAUDE_DIR, { recursive: true });
    log.ok('Repertoire cree');
  } else {
    log.ok('Repertoire existe');
  }

  log.step('\nCopie de statusline.sh');
  if (!flags.noBackup) {
    const b = backup(STATUSLINE_DST);
    if (b) log.info(`  ${C.dim}backup${C.reset} : ${b}`);
  }
  copyFileSync(statuslineSrc, STATUSLINE_DST);
  chmodSync(STATUSLINE_DST, 0o755);
  log.ok(`${STATUSLINE_DST} (chmod +x)`);

  log.step('\nMise a jour de settings.json');
  if (!flags.noBackup) {
    const b = backup(SETTINGS);
    if (b) log.info(`  ${C.dim}backup${C.reset} : ${b}`);
  }
  mergeSettings();
  log.ok('statusLine ajoute/mis a jour');

  log.title('Installation terminee');
  log.info(`${C.bold}Prochaine etape${C.reset} : redemarre Claude Code pour voir la statusline.`);
  log.info('');
  log.info(`${C.dim}Tester manuellement :${C.reset}`);
  log.info(
    `  echo '{"model":"claude-opus-4-7","cost":{"totalCostUsd":0},"session":{}}' | ${STATUSLINE_DST}`
  );
  log.info('');
}

export async function uninstall({ flags }) {
  if (existsSync(STATUSLINE_DST)) {
    if (!flags.noBackup) {
      const b = backup(STATUSLINE_DST);
      if (b) log.info(`  ${C.dim}backup${C.reset} : ${b}`);
    }
    unlinkSync(STATUSLINE_DST);
    log.ok(`Supprime ${STATUSLINE_DST}`);
  } else {
    log.warn('statusline.sh absent de ~/.claude/');
  }

  if (existsSync(SETTINGS)) {
    if (!flags.noBackup) {
      const b = backup(SETTINGS);
      if (b) log.info(`  ${C.dim}backup${C.reset} : ${b}`);
    }
    const json = JSON.parse(readFileSync(SETTINGS, 'utf8'));
    if (json.statusLine) {
      delete json.statusLine;
      writeFileSync(SETTINGS, JSON.stringify(json, null, 2) + '\n');
      log.ok('Cle statusLine retiree de settings.json');
    } else {
      log.warn('Aucune cle statusLine dans settings.json');
    }
  }

  log.info('');
  log.info(`${C.dim}Les caches /tmp/claude-sl-* expireront d'eux-memes.${C.reset}`);
}

export async function doctor() {
  log.step('OS');
  log.info(`  platform : linux${detectWsl() ? ' (WSL2)' : ''}`);
  log.info(`  kernel   : ${cmdOutput('uname -r')}`);

  log.step('\nDependances');
  for (const d of ['jq', 'curl', 'git', 'bash']) {
    if (has(d)) {
      const v = cmdOutput(`${d} --version 2>&1 | head -1`);
      log.ok(`${d} : ${v}`);
    } else {
      log.err(`${d} : manquant`);
    }
  }

  log.step('\nFichiers Claude Code');
  if (existsSync(STATUSLINE_DST)) log.ok(STATUSLINE_DST);
  else log.err(`${STATUSLINE_DST} manquant (lance : install)`);

  if (existsSync(SETTINGS)) {
    try {
      const json = JSON.parse(readFileSync(SETTINGS, 'utf8'));
      if (json.statusLine?.command)
        log.ok(`settings.json -> statusLine : ${json.statusLine.command}`);
      else log.err('settings.json existe mais cle statusLine absente');
    } catch (e) {
      log.err(`settings.json illisible : ${e.message}`);
    }
  } else {
    log.err(`${SETTINGS} manquant`);
  }

  log.step('\nCredentials (OAuth usage)');
  const creds = join(CLAUDE_DIR, '.credentials.json');
  if (existsSync(creds)) log.ok('.credentials.json present');
  else log.warn(".credentials.json absent - les quotas 5h/7j ne s'afficheront pas");
}
