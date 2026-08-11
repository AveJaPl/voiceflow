#!/usr/bin/env node
import { RelayMacSimClient } from './src/client.js';
import { ensureDesktopAsset } from './src/desktopImage.js';

const SCENARIOS = new Set(['happy', 'windowGone', 'focusFailed', 'busy', 'silent', 'dropMidUtterance', 'noCaps']);

function usage(message) {
  if (message) console.error(`[macsim] ${message}`);
  console.error('Użycie: node tools/macsim/server.js --relay ws://127.0.0.1:8091 --token <token> [--scenario nazwa]');
  process.exit(1);
}

function parseArgs(args) {
  const result = { scenario: 'happy' };
  for (let index = 0; index < args.length; index += 1) {
    const key = args[index];
    if (key === '--relay' || key === '--token' || key === '--scenario') {
      const value = args[index + 1];
      if (!value) usage(`Brakuje wartości po ${key}.`);
      result[key.slice(2)] = value;
      index += 1;
    } else {
      usage(`Nieznany argument: ${key}`);
    }
  }
  if (!result.relay || !result.token) usage('--relay i --token są wymagane.');
  if (!SCENARIOS.has(result.scenario)) usage(`Nieznany scenariusz: ${result.scenario}.`);
  return result;
}

const options = parseArgs(process.argv.slice(2));
ensureDesktopAsset();
const client = new RelayMacSimClient(options);
client.start();

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    client.stop();
    process.exit(0);
  });
}
