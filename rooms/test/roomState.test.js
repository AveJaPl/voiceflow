import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createRoomState, join, leave, startSpeaking, stopSpeaking, heartbeat, expire,
  speakerList, isMode, HEARTBEAT_TIMEOUT_MS,
} from '../src/roomState.js';

/** Kto mówi, po imieniu — testy nie muszą znać kształtu mapy mówiących. */
const speaking = (state) => speakerList(state).map((item) => item.name);

test('pierwszy chętny dostaje głos', () => {
  const state = join(createRoomState(), 'filip', 'Filip');
  const result = startSpeaking(state, 'filip', 1000);
  assert.equal(result.accepted, true);
  assert.deepEqual(speaking(result.state), ['Filip']);
});

test('drugi dostaje odmowę z nazwą mówiącego', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  const result = startSpeaking(state, 'wojtek', 1200);
  assert.equal(result.accepted, false);
  assert.equal(result.blockedBy, 'Filip');
  assert.deepEqual(speaking(result.state), ['Filip'], 'odmowa nie zmienia mówiącego');
});

test('nie ma przejęcia — powtórna próba też odpada', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = startSpeaking(state, 'wojtek', 1200).state;
  const second = startSpeaking(state, 'wojtek', 1400);
  assert.equal(second.accepted, false, 'twarda blokada: drugie naciśnięcie nie przejmuje');
});

test('po zakończeniu mówienia głos jest wolny i liczby są zapamiętane', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  state = stopSpeaking(state, 'filip', 5000, { words: 12, seconds: 4 });
  assert.deepEqual(speaking(state), []);
  assert.deepEqual(state.pending, [{ deviceId: 'filip', words: 12, seconds: 4, at: 5000 }]);
});

test('mówiący bez pulsu przez 10 s przestaje blokować', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = expire(state, 1000 + HEARTBEAT_TIMEOUT_MS + 1);
  assert.deepEqual(speaking(state), [], 'zawieszony klient nie blokuje pokoju bezterminowo');
  assert.equal(startSpeaking(state, 'wojtek', 12_000).accepted, true);
});

test('puls przedłuża blokadę', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  state = heartbeat(state, 'filip', 9000);
  state = expire(state, 12_000);
  assert.deepEqual(speaking(state), ['Filip'], 'puls w trakcie utrzymuje blokadę');
});

test('mówienie bez dołączenia jest odrzucane', () => {
  const result = startSpeaking(createRoomState(), 'obcy', 1000);
  assert.equal(result.accepted, false);
});

test('wyjście mówiącego zwalnia głos', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = leave(state, 'filip');
  assert.deepEqual(speaking(state), []);
  assert.equal(startSpeaking(state, 'wojtek', 1100).accepted, true);
});

test('ponowne naciśnięcie przez tego samego mówiącego nie psuje stanu', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  const again = startSpeaking(state, 'filip', 1500);
  assert.equal(again.accepted, true);
  assert.deepEqual(speaking(again.state), ['Filip']);
  assert.equal(speakerList(again.state)[0].since, 1500);
});

/* --- tryb zdalny: pokój bez kolejki do mikrofonu -------------------------- */

test('bez wyłączności dwie osoby mówią naraz', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000, { exclusive: false }).state;
  const result = startSpeaking(state, 'wojtek', 1100, { exclusive: false });

  assert.equal(result.accepted, true, 'nie siedzą w jednym pokoju — nie ma czego blokować');
  assert.equal(result.blockedBy, null);
  assert.deepEqual(speaking(result.state), ['Filip', 'Wojtek'], 'od najdawniej mówiącego');
});

test('bez wyłączności każdy kończy swoje dyktowanie osobno', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000, { exclusive: false }).state;
  state = startSpeaking(state, 'wojtek', 1100, { exclusive: false }).state;

  state = stopSpeaking(state, 'wojtek', 4000, { words: 30, seconds: 3 });

  assert.deepEqual(speaking(state), ['Filip'], 'koniec cudzego dyktowania nie kończy mojego');
  assert.deepEqual(state.pending, [{ deviceId: 'wojtek', words: 30, seconds: 3, at: 4000 }]);
});

test('puls jednego mówiącego nie przedłuża drugiego', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000, { exclusive: false }).state;
  state = startSpeaking(state, 'wojtek', 1000, { exclusive: false }).state;

  state = heartbeat(state, 'filip', 9000);
  state = expire(state, 1000 + HEARTBEAT_TIMEOUT_MS + 1);

  assert.deepEqual(speaking(state), ['Filip'], 'martwy klient znika sam, żywy zostaje');
});

test('nazwy trybów są zamknięte na liście', () => {
  assert.equal(isMode('together'), true);
  assert.equal(isMode('remote'), true);
  assert.equal(isMode('anything'), false, 'cudza wartość z żądania nie może stać się trybem');
});
