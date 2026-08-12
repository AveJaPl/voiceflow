import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountStore } from '../src/accountStore.js';

function withStore(fn) {
  const store = new AccountStore(':memory:');
  try {
    fn(store);
  } finally {
    store.close();
  }
}

test('hasło jest trzymane jako hash bcrypt, nie plaintext', () => {
  withStore((store) => {
    store.register('wojtek@programo.pl', 'haslo-testowe');
    const row = store.db.prepare('SELECT password_hash FROM accounts').get();
    assert.notEqual(row.password_hash, 'haslo-testowe');
    assert.match(row.password_hash, /^\$2[aby]\$/);
  });
});

test('login zwraca ten sam pairToken co rejestracja, mail bez względu na wielkość liter', () => {
  withStore((store) => {
    const { pairToken } = store.register('Wojtek@Programo.pl', 'haslo-testowe');
    assert.equal(store.login('wojtek@programo.pl', 'haslo-testowe'), pairToken);
    assert.equal(store.login('wojtek@programo.pl', 'zle'), null);
  });
});

test('findByPairToken znajduje konto po stałym tokenie i odrzuca pusty', () => {
  withStore((store) => {
    const { pairToken, id } = store.register('wojtek@programo.pl', 'haslo-testowe');
    assert.equal(store.findByPairToken(pairToken).id, id);
    assert.equal(store.findByPairToken('obcy-token'), null);
    assert.equal(store.findByPairToken(null), null);
  });
});

test('recentSessions zwraca wpisy od najnowszego i respektuje limit', () => {
  withStore((store) => {
    const { id } = store.register('wojtek@programo.pl', 'haslo-testowe');
    store.logEvent({ accountId: id, role: 'mac', event: 'connected' });
    const phoneId = store.logEvent({ accountId: id, role: 'phone', event: 'connected' });
    store.setDevice(phoneId, 'iPhone Wojtka');

    const all = store.recentSessions(50);
    assert.equal(all.length, 2);
    assert.equal(all[0].role, 'phone');
    assert.equal(all[0].device, 'iPhone Wojtka');
    assert.equal(store.recentSessions(1).length, 1);
  });
});
