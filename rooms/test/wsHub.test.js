import test from 'node:test';
import assert from 'node:assert/strict';
import { createHub } from '../src/wsHub.js';

function fakeConnection(deviceId, name) {
  return {
    deviceId,
    name,
    roomCode: 'ROOM01',
    roomId: 1,
    sent: [],
    send(obj) { this.sent.push(obj); },
  };
}

const noopStore = {
  async activeSession() { return { id: 1 }; },
  async recordDictation() {},
};

test('drugi mówiący dostaje odmowę z nazwą blokującego', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });

  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);
  await hub.handleMessage(wojtek, { type: 'speaking_started' }, 1100);

  const denial = wojtek.sent.find((m) => m.type === 'speaking_denied');
  assert.ok(denial, 'odmowa musi trafić do odrzuconego');
  assert.equal(denial.blockedBy, 'Filip');
});

test('start mówienia rozgłasza się do pozostałych, ale nie do mówiącego', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });

  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  const toWojtek = wojtek.sent.filter((m) => m.type === 'speaker_changed');
  assert.equal(toWojtek.at(-1).speaking.name, 'Filip');
  assert.equal(
    filip.sent.filter((m) => m.type === 'speaker_changed').length, 0,
    'mówiący nie ścisza sobie dźwięku tym kanałem — robi to jego własny skrót',
  );
});

test('koniec mówienia zapisuje liczby do bazy', async () => {
  const recorded = [];
  const store = {
    async activeSession() { return { id: 7 }; },
    async recordDictation(sessionId, deviceId, at, seconds, words) {
      recorded.push({ sessionId, deviceId, seconds, words });
    },
  };
  const hub = createHub({ store });
  const filip = fakeConnection('f', 'Filip');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);
  await hub.handleMessage(filip, { type: 'speaking_ended', words: 9, seconds: 3.5 }, 4500);

  assert.deepEqual(recorded, [{ sessionId: 7, deviceId: 'f', seconds: 3.5, words: 9 }]);
});

test('błąd zapisu do bazy nie przerywa pokoju', async () => {
  const store = {
    async activeSession() { return { id: 7 }; },
    async recordDictation() { throw new Error('baza padła'); },
  };
  const hub = createHub({ store });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  await hub.handleMessage(filip, { type: 'speaking_ended', words: 9, seconds: 3.5 }, 4500);

  const last = wojtek.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(last.speaking, null, 'głos jest zwolniony mimo nieudanego zapisu statystyki');
});

test('tick zdejmuje blokadę po martwym mówiącym i powiadamia pokój', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  hub.tick(1000 + 10_001);

  const last = wojtek.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(last.speaking, null, 'pokój dowiaduje się, że można znów mówić');
});

test('rozłączenie mówiącego zwalnia głos', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  hub.disconnect(filip);

  const last = wojtek.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(last.speaking, null);
});

test('hello zwraca aktualny stan pokoju nowemu klientowi', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(wojtek, { type: 'hello' });

  const state = wojtek.sent.find((m) => m.type === 'room_state');
  assert.equal(state.speaking.name, 'Filip', 'dołączający od razu wie, że ktoś mówi');
});

test('pokoje są od siebie odizolowane', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const obcy = { ...fakeConnection('x', 'Obcy'), roomCode: 'INNY99' };
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(obcy, { type: 'hello' });

  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  assert.equal(
    obcy.sent.filter((m) => m.type === 'speaker_changed').length, 0,
    'cudzy pokój nie ścisza nam głośnika',
  );
});

test('widz patrzy, ale nie może mówić ani wejść do składu', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const tablet = { ...fakeConnection('v', null), viewer: true };
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(tablet, { type: 'hello' });

  await hub.handleMessage(tablet, { type: 'speaking_started' }, 1000);
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1100);

  assert.equal(
    tablet.sent.filter((m) => m.type === 'speaking_denied').length, 0,
    'widz nie próbuje mówić, więc nie dostaje odmowy',
  );
  const toTablet = tablet.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(toTablet.speaking.name, 'Filip', 'ale widzi, kto mówi');
});

test('anulowanie zwalnia głos, ale nie tworzy wpisu w rankingu', async () => {
  const recorded = [];
  const store = {
    async activeSession() { return { id: 7 }; },
    async recordDictation(...args) { recorded.push(args); },
  };
  const hub = createHub({ store });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  await hub.handleMessage(filip, { type: 'speaking_ended', words: 0, seconds: 0 }, 1500);

  assert.deepEqual(recorded, [], 'puste dyktowanie nie zaniża średniej');
  const last = wojtek.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(last.speaking, null, 'ale głos jest wolny NATYCHMIAST, bez czekania na puls');
  const again = await hub.handleMessage(wojtek, { type: 'speaking_started' }, 1600);
  assert.equal(
    wojtek.sent.filter((m) => m.type === 'speaking_denied').length, 0,
    'druga osoba może od razu mówić',
  );
});
