import { DISPLAY, cloneWindows } from './windows.js';

export const TRANSCRIPT_PHRASES = [
  'napisz',
  'napisz test',
  'napisz test do RemoteSession',
  'napisz test do RemoteSession i odpal go',
];

export const TERMINAL_BASE_LINES = [
  '╭──────────────── Claude Code ────────────────╮',
  '│ workspace: ~/Programo/voiceflow             │',
  '╰─────────────────────────────────────────────╯',
  '',
  '› Sprawdzam implementację RemoteSession.',
  '  ⎿  Read ios/VoiceFlowApp/Remote/RemoteSession.swift',
  '',
  '› Widzę maszynę stanów i timeouty.',
  '  ⎿  Running tests for remote control…',
  '',
  '  RemoteSessionTests',
  '    ✓ arming waits for started',
  '    ✓ timeout clears buffered PCM',
  '    ✓ injected returns to idle',
  '',
  '───────────────────────────────────────────────',
  '',
  'Do you want me to add an integration test?',
  '',
  '───────────────────────────────────────────────',
  '',
  'Press Enter to accept · Esc to cancel',
  '',
  '───────────────────────────────────────────────',
  '',
  'Claude is ready.',
  '',
  '› ',
];

function capsForScenario(scenario) {
  const enabled = scenario !== 'noCaps';
  return { screenshot: enabled, terminalText: enabled, move: enabled };
}

export function createMacState({ scenario = 'happy', windows } = {}) {
  return {
    scenario,
    caps: capsForScenario(scenario),
    generation: 1,
    displays: [{ ...DISPLAY }],
    windows: cloneWindows(windows),
    subscription: { windows: false, screenshot: false, terminal: null },
    utterance: null,
    startAttempts: 0,
    audio: { acceptedBytes: 0, rejectedBytes: 0 },
    terminal: { seq: 0, revision: 0, lines: [...TERMINAL_BASE_LINES] },
  };
}

export function windowsFrame(state) {
  return {
    type: 'windows',
    generation: state.generation,
    displays: state.displays.map((display) => ({ ...display })),
    windows: cloneWindows(state.windows),
  };
}

export function focusedWindow(state) {
  return state.windows.find((window) => window.focused) ?? null;
}

export function findWindow(state, id) {
  return state.windows.find((window) => window.id === id) ?? null;
}

export function isTerminalWindow(state, id) {
  return findWindow(state, id)?.kind === 'terminal';
}

export function replaceWindows(state, windows, { changed = true } = {}) {
  return {
    ...state,
    windows: cloneWindows(windows),
    generation: changed ? state.generation + 1 : state.generation,
  };
}

export function focusWindowState(state, id) {
  const target = findWindow(state, id);
  if (!target) return { state, changed: false };
  if (target.focused) return { state, changed: false };
  const windows = state.windows.map((window) => {
    if (window.id === id) return { ...window, focused: true, z: 0 };
    return { ...window, focused: false, z: window.z < target.z ? window.z + 1 : window.z };
  });
  return { state: replaceWindows(state, windows), changed: true };
}

export function moveWindowState(state, id, rect) {
  const target = findWindow(state, id);
  if (!target) return { state, changed: false };
  const changed = ['x', 'y', 'w', 'h'].some((key) => target[key] !== rect[key]);
  if (!changed) return { state, changed: false };
  const windows = state.windows.map((window) => (window.id === id ? { ...window, ...rect } : window));
  return { state: replaceWindows(state, windows), changed: true };
}

export function removeWindowState(state, id) {
  if (!findWindow(state, id)) return { state, changed: false };
  return { state: replaceWindows(state, state.windows.filter((window) => window.id !== id)), changed: true };
}

export function withAudioBytes(state, byteLength) {
  const key = state.utterance?.phase === 'streaming' ? 'acceptedBytes' : 'rejectedBytes';
  return { ...state, audio: { ...state.audio, [key]: state.audio[key] + byteLength } };
}
