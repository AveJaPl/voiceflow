import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createRoomState, join, leave, startSpeaking, stopSpeaking, heartbeat, expire,
  HEARTBEAT_TIMEOUT_MS,
} from '../src/roomState.js';

test('pierwszy chętny dostaje głos', () => {
  const state = join(createRoomState(), 'filip', 'Filip');
  const result = startSpeaking(state, 'filip', 1000);
  assert.equal(result.accepted, true);
  assert.equal(result.state.speaking.deviceId, 'filip');
});

test('drugi dostaje odmowę z nazwą mówiącego', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  const result = startSpeaking(state, 'wojtek', 1200);
  assert.equal(result.accepted, false);
  assert.equal(result.blockedBy, 'Filip');
  assert.equal(result.state.speaking.deviceId, 'filip', 'odmowa nie zmienia mówiącego');
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
  assert.equal(state.speaking, null);
  assert.deepEqual(state.pending, [{ deviceId: 'filip', words: 12, seconds: 4, at: 5000 }]);
});

test('mówiący bez pulsu przez 10 s przestaje blokować', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = expire(state, 1000 + HEARTBEAT_TIMEOUT_MS + 1);
  assert.equal(state.speaking, null, 'zawieszony klient nie blokuje pokoju bezterminowo');
  assert.equal(startSpeaking(state, 'wojtek', 12_000).accepted, true);
});

test('puls przedłuża blokadę', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  state = heartbeat(state, 'filip', 9000);
  state = expire(state, 12_000);
  assert.equal(state.speaking?.deviceId, 'filip', 'puls w trakcie utrzymuje blokadę');
});

test('mówienie bez dołączenia jest odrzucane', () => {
  const result = startSpeaking(createRoomState(), 'obcy', 1000);
  assert.equal(result.accepted, false);
});

test('wyjście mówiącego zwalnia głos', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = leave(state, 'filip');
  assert.equal(state.speaking, null);
  assert.equal(startSpeaking(state, 'wojtek', 1100).accepted, true);
});

test('ponowne naciśnięcie przez tego samego mówiącego nie psuje stanu', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  const again = startSpeaking(state, 'filip', 1500);
  assert.equal(again.accepted, true);
  assert.equal(again.state.speaking.since, 1500);
});
