import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  completeInjected,
  completeStarted,
  handleBinaryFrame,
  handlePhoneFrame,
  previewTick,
  terminalTick,
} from '../src/handlers.js';
import { createMacState } from '../src/state.js';

function frames(actions, type) {
  return actions.filter((action) => action.kind === 'send' && action.frame.type === type).map((action) => action.frame);
}

function startFrame(state, target = state.windows[0].id) {
  return { type: 'start', target, generation: state.generation };
}

test('start z nieaktualną generation zwraca windowGone i nigdy nie planuje started', () => {
  const state = createMacState();
  const result = handlePhoneFrame(state, { type: 'start', target: state.windows[0].id, generation: 0 });

  assert.equal(frames(result.actions, 'error')[0].code, 'windowGone');
  assert.equal(frames(result.actions, 'windows').length, 1);
  assert.equal(result.actions.some((action) => action.kind === 'scheduleStarted'), false);
  assert.equal(frames(result.actions, 'started').length, 0);
  assert.equal(frames(completeStarted(result.state, state.windows[0].id).actions, 'started').length, 0);
});

test('start na nieistniejące id zwraca windowGone i zero started', () => {
  const state = createMacState();
  const result = handlePhoneFrame(state, { type: 'start', target: 'nie-ma', generation: state.generation });

  assert.equal(frames(result.actions, 'error')[0].code, 'windowGone');
  assert.equal(frames(result.actions, 'windows').length, 1);
  assert.equal(result.actions.some((action) => action.kind === 'scheduleStarted'), false);
});

test('drugi start podczas wypowiedzi zwraca busy i nie tworzy drugiego started', () => {
  let state = createMacState();
  const first = handlePhoneFrame(state, startFrame(state));
  state = first.state;
  const started = completeStarted(state, state.utterance.target);
  state = started.state;
  const second = handlePhoneFrame(state, startFrame(state));

  assert.equal(frames(started.actions, 'started').length, 1);
  assert.equal(frames(second.actions, 'error')[0].code, 'busy');
  assert.equal(second.actions.some((action) => action.kind === 'scheduleStarted'), false);
  assert.equal(frames(second.actions, 'started').length, 0);
});

test('scenariusz focusFailed zwraca focusFailed i zero started', () => {
  const state = createMacState({ scenario: 'focusFailed' });
  const result = handlePhoneFrame(state, startFrame(state));

  assert.equal(frames(result.actions, 'error')[0].code, 'focusFailed');
  assert.equal(result.actions.some((action) => action.kind === 'scheduleStarted'), false);
});

test('szczęśliwa ścieżka: started, preview i injected z ostatnim preview', () => {
  let state = createMacState();
  const arm = handlePhoneFrame(state, startFrame(state));
  assert.equal(arm.actions.some((action) => action.kind === 'scheduleStarted'), true);
  state = completeStarted(arm.state, arm.state.utterance.target).state;
  const preview1 = previewTick(state);
  state = preview1.state;
  const preview2 = previewTick(state);
  state = preview2.state;
  const previewText = frames(preview2.actions, 'preview')[0].text;
  const ending = handlePhoneFrame(state, { type: 'end' });
  const injected = completeInjected(ending.state, state.utterance.target);

  assert.equal(frames(completeStarted(arm.state, arm.state.utterance.target).actions, 'started').length, 1);
  assert.equal(previewText, 'napisz test');
  assert.equal(frames(injected.actions, 'injected')[0].text, previewText);
  assert.equal(frames(injected.actions, 'injected')[0].via, 'clipboard');
});

test('cancel kończy wypowiedź bez injected', () => {
  let state = createMacState();
  state = completeStarted(handlePhoneFrame(state, startFrame(state)).state, state.windows[0].id).state;
  const cancelled = handlePhoneFrame(state, { type: 'cancel' });
  const late = completeInjected(cancelled.state, state.windows[0].id);

  assert.equal(cancelled.state.utterance, null);
  assert.equal(frames(late.actions, 'injected').length, 0);
});

test('PCM przed start i po end jest odrzucany oraz osobno liczony', () => {
  let state = createMacState();
  state = handleBinaryFrame(state, 8).state;
  state = completeStarted(handlePhoneFrame(state, startFrame(state)).state, state.windows[0].id).state;
  state = handleBinaryFrame(state, 12).state;
  const ending = handlePhoneFrame(state, { type: 'end' });
  state = completeInjected(ending.state, state.windows[0].id).state;
  state = handleBinaryFrame(state, 16).state;

  assert.equal(state.audio.acceptedBytes, 12);
  assert.equal(state.audio.rejectedBytes, 24);
});

test('focusWindow podbija generation i dokładnie jedno okno jest focused', () => {
  const state = createMacState();
  const target = state.windows[1];
  const result = handlePhoneFrame(state, { type: 'focusWindow', id: target.id, generation: state.generation });
  const snapshot = frames(result.actions, 'windows')[0];

  assert.equal(result.state.generation, state.generation + 1);
  assert.equal(snapshot.generation, result.state.generation);
  assert.deepEqual(result.state.windows.filter((window) => window.focused).map((window) => window.id), [target.id]);
  assert.equal(result.state.windows.find((window) => window.id === target.id).z, 0);
  assert.deepEqual(result.state.windows.map((window) => window.z).sort((a, b) => a - b), [0, 1, 2, 3]);
  assert.equal(frames(result.actions, 'focus')[0].app, 'iTerm2');
});

test('subscribe i unsubscribe włączają oraz wyłączają autonomiczne ramki terminala', () => {
  let state = createMacState();
  const terminalId = state.windows[0].id;
  const subscribed = handlePhoneFrame(state, { type: 'subscribe', windows: true, screenshot: false, terminal: terminalId });
  state = subscribed.state;
  const tick = terminalTick(state);
  const unsubscribed = handlePhoneFrame(tick.state, { type: 'unsubscribe' });
  const afterUnsubscribe = terminalTick(unsubscribed.state);

  assert.equal(frames(subscribed.actions, 'windows').length, 1);
  assert.equal(subscribed.actions.some((action) => action.kind === 'startTerminal'), true);
  assert.equal(frames(tick.actions, 'terminal').length, 1);
  assert.equal(frames(afterUnsubscribe.actions, 'terminal').length, 0);
  assert.equal(unsubscribed.actions.some((action) => action.kind === 'stopAutonomous'), true);
});

test('noCaps odmawia screenshot, terminala i przesunięcia wyłącznie kodem unsupported', () => {
  let state = createMacState({ scenario: 'noCaps' });
  const terminalId = state.windows[0].id;
  const sub = handlePhoneFrame(state, { type: 'subscribe', windows: false, screenshot: true, terminal: terminalId });
  state = sub.state;
  const move = handlePhoneFrame(state, { type: 'moveWindow', id: terminalId, generation: state.generation, x: 1, y: 1, w: 2, h: 2 });

  assert.deepEqual(frames(sub.actions, 'error').map((frame) => frame.code), ['unsupported', 'unsupported']);
  assert.equal(frames(move.actions, 'error')[0].code, 'unsupported');
});

test('generation jest monotoniczna przy focusie, przesunięciu i scenariuszu usunięcia okna', () => {
  let state = createMacState();
  const generations = [state.generation];
  state = handlePhoneFrame(state, { type: 'focusWindow', id: state.windows[1].id, generation: state.generation }).state;
  generations.push(state.generation);
  state = handlePhoneFrame(state, { type: 'moveWindow', id: state.windows[1].id, generation: state.generation, x: 1700, y: 90, w: 1600, h: 900 }).state;
  generations.push(state.generation);

  const goneState = createMacState({ scenario: 'windowGone' });
  const gone = handlePhoneFrame(goneState, startFrame(goneState));

  assert.deepEqual(generations, [1, 2, 3]);
  assert.equal(generations.every((generation, index) => index === 0 || generation >= generations[index - 1]), true);
  assert.equal('type' in state.windows[1], false);
  assert.equal('generation' in state.windows[1], false);
  assert.equal(gone.state.generation, 2);
});

test('pozostałe scenariusze start nie wysyłają started poza happy', () => {
  const busy = createMacState({ scenario: 'busy' });
  const silent = createMacState({ scenario: 'silent' });
  const dropping = createMacState({ scenario: 'dropMidUtterance' });
  const busyResult = handlePhoneFrame(busy, startFrame(busy));
  const silentResult = handlePhoneFrame(silent, startFrame(silent));
  const dropArm = handlePhoneFrame(dropping, startFrame(dropping));
  const dropStarted = completeStarted(dropArm.state, dropArm.state.utterance.target);

  assert.equal(frames(busyResult.actions, 'error')[0].code, 'busy');
  assert.equal(busyResult.actions.some((action) => action.kind === 'scheduleStarted'), false);
  assert.equal(silentResult.actions.some((action) => action.kind === 'scheduleStarted'), false);
  assert.equal(frames(completeStarted(silentResult.state, silentResult.state.utterance.target).actions, 'started').length, 0);
  assert.equal(frames(dropStarted.actions, 'started').length, 1);
  assert.equal(dropStarted.actions.some((action) => action.kind === 'dropLater'), true);
});
