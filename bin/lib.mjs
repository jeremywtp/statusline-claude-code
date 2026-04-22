// ============================================================================
// Helpers partages entre plateformes (log, color, exec, backup).
// ============================================================================

import { execSync } from 'node:child_process';
import { copyFileSync, existsSync } from 'node:fs';

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
