// ============================================================================
// Windows natif - non supporte (hint vers WSL2)
// ============================================================================

import { log, C } from '../lib.mjs';

function notSupported() {
  log.err('Windows natif non supporte.');
  log.info('');
  log.info(`Claude Code et ses scripts bash ne tournent pas en Windows natif.`);
  log.info(`Installe WSL2 et relance depuis une session Ubuntu :`);
  log.info('');
  log.info(`  1. ${C.cyan}wsl --install${C.reset}                                    (PowerShell admin)`);
  log.info(`  2. Redemarre la machine`);
  log.info(`  3. Lance Ubuntu depuis le menu Demarrer`);
  log.info(`  4. ${C.cyan}npm i -g @anthropic-ai/claude-code${C.reset}              (dans WSL)`);
  log.info(`  5. ${C.cyan}npx github:jeremywtp/statusline-claude-code${C.reset}     (dans WSL)`);
  log.info('');
}

export async function install() {
  notSupported();
  process.exit(1);
}

export async function uninstall() {
  log.err('Windows natif non supporte.');
  log.info('Lance la commande uninstall depuis WSL :');
  log.info(`  ${C.cyan}npx github:jeremywtp/statusline-claude-code uninstall${C.reset}`);
  process.exit(1);
}

export async function doctor() {
  log.warn('Windows natif detecte - lance les commandes statusline depuis WSL.');
  log.info('');
  log.info(`  Verifie que WSL est installe : ${C.cyan}wsl --list --verbose${C.reset}`);
  log.info(`  Si WSL absent                 : ${C.cyan}wsl --install${C.reset}`);
  log.info('');
}
