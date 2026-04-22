// ============================================================================
// macOS (Intel + Apple Silicon) - installer avec patch GNU via Homebrew
// ============================================================================

import { execSync } from 'node:child_process';
import {
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  chmodSync,
  unlinkSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { log, C, has, backup, cmdOutput } from '../lib.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SHIM_PATH = resolve(__dirname, '..', 'shims', 'macos.sh');

const CLAUDE_DIR = join(homedir(), '.claude');
const STATUSLINE_DST = join(CLAUDE_DIR, 'statusline.sh');
const SETTINGS = join(CLAUDE_DIR, 'settings.json');

// Apple Silicon d'abord (couvre 99% des Mac recents), Intel en fallback.
const HOMEBREW_BIN_DIRS = ['/opt/homebrew/bin', '/usr/local/bin'];

function detectHomebrewPrefix() {
  for (const bin of HOMEBREW_BIN_DIRS) {
    if (existsSync(`${bin}/brew`)) return dirname(bin); // /opt/homebrew ou /usr/local
  }
  return null;
}

function detectGnuBinDir() {
  // On detecte par la presence de gstat (coreutils), qui doit etre installe
  // pour que le shim fonctionne. Le chemin retourne est le meme que bin/brew.
  for (const bin of HOMEBREW_BIN_DIRS) {
    if (existsSync(`${bin}/gstat`)) return bin;
  }
  return null;
}

function detectBash5() {
  for (const bin of HOMEBREW_BIN_DIRS) {
    const bashPath = `${bin}/bash`;
    if (existsSync(bashPath)) {
      const out = cmdOutput(`${bashPath} --version 2>&1 | head -1`);
      const m = out.match(/bash, version (\d+)/);
      if (m && parseInt(m[1], 10) >= 5) return bashPath;
    }
  }
  return null;
}

function brewInstall(formulas) {
  if (!formulas.length) return;
  log.info(`  ${C.dim}brew install ${formulas.join(' ')}${C.reset}`);
  execSync(`brew install ${formulas.join(' ')}`, { stdio: 'inherit' });
}

function patchSource(source, shim, bash5Path) {
  // 1) Inserer le shim apres `set -euo pipefail` (idempotent).
  if (!source.includes('BEGIN macOS compat shim')) {
    const marker = 'set -euo pipefail\n';
    const idx = source.indexOf(marker);
    if (idx === -1) {
      throw new Error('Marker "set -euo pipefail" introuvable dans statusline.sh');
    }
    const before = source.slice(0, idx + marker.length);
    const after = source.slice(idx + marker.length);
    source = before + '\n' + shim + '\n' + after;
  }

  // 2) Reecrire le shebang vers bash 5+ Homebrew.
  const firstNewline = source.indexOf('\n');
  const firstLine = source.slice(0, firstNewline);
  if (firstLine.startsWith('#!')) {
    source = `#!${bash5Path}` + source.slice(firstNewline);
  }

  return source;
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
  log.step('Detection Homebrew');
  const brewPrefix = detectHomebrewPrefix();
  if (!brewPrefix) {
    log.err('Homebrew non trouve.');
    log.info('');
    log.info(`  Installe Homebrew :`);
    log.info(
      `  ${C.cyan}/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"${C.reset}`
    );
    log.info('');
    log.info(`  Puis relance : ${C.cyan}npx github:jeremywtp/statusline-claude-code${C.reset}`);
    log.info('');
    process.exit(1);
  }
  const arch = brewPrefix === '/opt/homebrew' ? 'Apple Silicon' : 'Intel';
  log.ok(`Homebrew : ${brewPrefix}  (${arch})`);

  log.step('\nVerification des dependances');
  // Map : binaire attendu -> formule Homebrew
  const bins = {
    gstat: 'coreutils',
    gdate: 'coreutils',
    gmd5sum: 'coreutils',
    gfind: 'findutils',
    ggrep: 'grep',
    jq: 'jq',
    curl: 'curl',
    git: 'git',
  };
  const gnuBin = `${brewPrefix}/bin`;
  const toInstall = new Set();

  for (const [bin, formula] of Object.entries(bins)) {
    const p = `${gnuBin}/${bin}`;
    if (existsSync(p)) log.ok(`${bin} (${formula})`);
    else {
      log.warn(`${bin} (${formula}) manquant`);
      toInstall.add(formula);
    }
  }

  // Bash 5+
  let bash5 = detectBash5();
  if (bash5) log.ok(`bash 5+ : ${bash5}`);
  else {
    log.warn('bash 5+ manquant');
    toInstall.add('bash');
  }

  if (toInstall.size) {
    log.step('\nInstallation des dependances manquantes');
    brewInstall([...toInstall]);
    // Re-detection apres install
    bash5 = detectBash5();
    if (!bash5) throw new Error('bash 5+ toujours introuvable apres brew install');
  } else {
    log.ok('Toutes les dependances sont presentes');
  }

  log.step('\nPreparation de ~/.claude/');
  if (!existsSync(CLAUDE_DIR)) {
    mkdirSync(CLAUDE_DIR, { recursive: true });
    log.ok('Repertoire cree');
  } else {
    log.ok('Repertoire existe');
  }

  log.step('\nPatch macOS du statusline.sh');
  const vanilla = readFileSync(statuslineSrc, 'utf8');
  const shim = readFileSync(SHIM_PATH, 'utf8');
  const patched = patchSource(vanilla, shim, bash5);

  if (!flags.noBackup) {
    const b = backup(STATUSLINE_DST);
    if (b) log.info(`  ${C.dim}backup${C.reset} : ${b}`);
  }
  writeFileSync(STATUSLINE_DST, patched);
  chmodSync(STATUSLINE_DST, 0o755);
  log.ok(`shim insere (${shim.split('\n').filter(Boolean).length} lignes)`);
  log.ok(`shebang -> #!${bash5}`);
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
  log.info(
    `${C.dim}Les deps Homebrew (coreutils, findutils, grep, bash) restent installees (retire-les manuellement si besoin).${C.reset}`
  );
}

export async function doctor() {
  log.step('OS');
  log.info(`  platform : macOS ${cmdOutput('sw_vers -productVersion')}`);
  log.info(`  arch     : ${cmdOutput('uname -m')}`);

  log.step('\nHomebrew');
  const brewPrefix = detectHomebrewPrefix();
  if (brewPrefix) log.ok(`${brewPrefix}`);
  else log.err('non installe');

  log.step('\nDependances GNU (coreutils/findutils/grep)');
  const bins = ['gstat', 'gdate', 'gmd5sum', 'gfind', 'ggrep'];
  const gnuBin = detectGnuBinDir();
  for (const b of bins) {
    const found = HOMEBREW_BIN_DIRS.map((d) => `${d}/${b}`).find(existsSync);
    if (found) log.ok(`${b} : ${found}`);
    else log.err(`${b} : manquant`);
  }

  log.step('\nBash 5+');
  const bash5 = detectBash5();
  if (bash5) log.ok(`${bash5}`);
  else log.err('manquant');

  log.step('\nAutres dependances');
  for (const d of ['jq', 'curl', 'git']) {
    if (has(d)) log.ok(`${d} : ${cmdOutput(`${d} --version 2>&1 | head -1`)}`);
    else log.err(`${d} : manquant`);
  }

  log.step('\nFichiers Claude Code');
  if (existsSync(STATUSLINE_DST)) {
    log.ok(STATUSLINE_DST);
    const content = readFileSync(STATUSLINE_DST, 'utf8');
    if (content.includes('BEGIN macOS compat shim')) log.ok('  shim macOS present');
    else log.err('  shim macOS ABSENT -- reinstalle');
    const shebang = content.split('\n')[0];
    if (shebang.startsWith('#!') && shebang.includes('homebrew')) log.ok(`  shebang : ${shebang}`);
    else if (shebang.startsWith('#!') && shebang.includes('/usr/local/bin/bash'))
      log.ok(`  shebang : ${shebang}`);
    else log.warn(`  shebang : ${shebang}  (pas bash 5+ Homebrew)`);
  } else {
    log.err(`${STATUSLINE_DST} manquant (lance : install)`);
  }

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
