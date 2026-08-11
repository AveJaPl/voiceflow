import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PairingStore } from '../src/pairingStore.js';

function tempStorePath() {
  const dir = mkdtempSync(join(tmpdir(), 'voiceflow-relay-test-'));
  return join(dir, 'pairing.json');
}

test('generate() tworzy token i jest on od razu ważny', () => {
  const store = new PairingStore(tempStorePath());
  const { token } = store.generate();

  assert.ok(token.length >= 32);
  assert.equal(store.isValid(token), true);
});

test('generate() unieważnia poprzedni token', () => {
  const store = new PairingStore(tempStorePath());
  const first = store.generate();
  const second = store.generate();

  assert.notEqual(first.token, second.token);
  assert.equal(store.isValid(first.token), false);
  assert.equal(store.isValid(second.token), true);
});

test('isValid() odrzuca losowy string i brak tokenu', () => {
  const store = new PairingStore(tempStorePath());
  assert.equal(store.isValid('cokolwiek'), false);

  store.generate();
  assert.equal(store.isValid(undefined), false);
  assert.equal(store.isValid(''), false);
});

test('token przetrwa restart procesu (nowa instancja czyta ten sam plik)', () => {
  const path = tempStorePath();
  const first = new PairingStore(path);
  const { token } = first.generate();

  const second = new PairingStore(path);
  assert.equal(second.isValid(token), true);
});

test('brak pliku na starcie = brak aktywnego tokenu, nie wywala się', () => {
  const store = new PairingStore(tempStorePath());
  assert.equal(store.current(), null);
  assert.equal(store.isValid('token'), false);
});
