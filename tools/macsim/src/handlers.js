import {
  TRANSCRIPT_PHRASES,
  findWindow,
  focusWindowState,
  focusedWindow,
  isTerminalWindow,
  moveWindowState,
  removeWindowState,
  windowsFrame,
  withAudioBytes,
} from './state.js';

const ERROR_CODES = new Set(['windowGone', 'focusFailed', 'busy', 'notPermitted', 'unsupported', 'timeout']);

function send(frame) {
  return { kind: 'send', frame };
}

function error(code, { message, target, text } = {}) {
  if (!ERROR_CODES.has(code)) throw new Error(`Niedozwolony kod błędu: ${code}`);
  return send({ type: 'error', code, ...(message ? { message } : {}), ...(target ? { target } : {}), ...(text ? { text } : {}) });
}

function replyWindows(state, actions) {
  actions.push(send(windowsFrame(state)));
}

function stateChangeWindows(state, actions, changed) {
  if (changed && state.subscription.windows) replyWindows(state, actions);
}

function currentTarget(state, requestedTarget) {
  return requestedTarget ? findWindow(state, requestedTarget) : focusedWindow(state);
}

/**
 * Czysty dekoder tylko dla tekstowych ramek telefonu. Nieznany/zepsuty tekst
 * zostaje zignorowany, tak aby pojedyncza ramka nie zrywała symulacji.
 */
export function decodePhoneFrame(text) {
  try {
    const frame = JSON.parse(text);
    return frame && typeof frame.type === 'string' ? frame : null;
  } catch {
    return null;
  }
}

/** Czyste przejście stanu: zwraca nowy stan oraz deklaratywne efekty I/O/timerów. */
export function handlePhoneFrame(state, frame) {
  if (!frame || typeof frame.type !== 'string') return { state, actions: [] };
  const actions = [];

  switch (frame.type) {
    case 'hello':
      actions.push(send({ type: 'hello', protocol: 1, mac: 'macsim', caps: { ...state.caps } }));
      return { state, actions };

    case 'subscribe': {
      const subscription = {
        windows: frame.windows === true,
        screenshot: frame.screenshot === true,
        terminal: typeof frame.terminal === 'string' ? frame.terminal : null,
      };
      let next = { ...state, subscription };
      if (subscription.windows) replyWindows(next, actions);
      if (subscription.screenshot) {
        if (next.caps.screenshot) actions.push({ kind: 'screenshot' });
        else actions.push(error('unsupported', { message: 'macsim nie udostępnia zrzutów ekranu w tym scenariuszu.' }));
      }
      if (subscription.terminal) {
        if (!next.caps.terminalText) {
          next = { ...next, subscription: { ...subscription, terminal: null } };
          actions.push(error('unsupported', { message: 'macsim nie udostępnia tekstu terminala w tym scenariuszu.', target: subscription.terminal }));
        } else if (isTerminalWindow(next, subscription.terminal)) {
          actions.push({ kind: 'startTerminal' });
        }
      }
      return { state: next, actions };
    }

    case 'unsubscribe':
      return {
        state: { ...state, subscription: { windows: false, screenshot: false, terminal: null } },
        actions: [{ kind: 'stopAutonomous' }],
      };

    case 'requestWindows':
      replyWindows(state, actions);
      return { state, actions };

    case 'requestScreenshot':
      if (state.caps.screenshot) actions.push({ kind: 'screenshot' });
      else actions.push(error('unsupported', { message: 'macsim nie udostępnia zrzutów ekranu w tym scenariuszu.' }));
      return { state, actions };

    case 'focusWindow': {
      if (frame.generation !== state.generation || !findWindow(state, frame.id)) {
        actions.push(error('windowGone', { message: 'Okno nie istnieje albo migawka jest nieaktualna.', target: frame.id }));
        replyWindows(state, actions);
        return { state, actions };
      }
      const result = focusWindowState(state, frame.id);
      const target = findWindow(result.state, frame.id);
      replyWindows(result.state, actions);
      actions.push(send({ type: 'focus', app: target.app, window: target.title }));
      return { state: result.state, actions };
    }

    case 'moveWindow': {
      if (!state.caps.move) {
        actions.push(error('unsupported', { message: 'macsim nie obsługuje przesuwania okien w tym scenariuszu.', target: frame.id }));
        return { state, actions };
      }
      if (frame.generation !== state.generation || !findWindow(state, frame.id)) {
        actions.push(error('windowGone', { message: 'Okno nie istnieje albo migawka jest nieaktualna.', target: frame.id }));
        replyWindows(state, actions);
        return { state, actions };
      }
      const result = moveWindowState(state, frame.id, { x: frame.x, y: frame.y, w: frame.w, h: frame.h });
      replyWindows(result.state, actions);
      return { state: result.state, actions };
    }

    case 'start':
      return handleStart(state, frame);

    case 'end':
      if (!state.utterance) return { state, actions };
      if (state.utterance.phase !== 'streaming') {
        return { state: { ...state, utterance: null }, actions: [{ kind: 'stopPreview' }] };
      }
      return {
        state: { ...state, utterance: { ...state.utterance, phase: 'finishing' } },
        actions: [{ kind: 'stopPreview' }, { kind: 'scheduleInjected', target: state.utterance.target }],
      };

    case 'cancel':
      return { state: { ...state, utterance: null }, actions: [{ kind: 'stopPreview' }] };

    case 'key':
      return { state, actions: [{ kind: 'logKey', chord: frame.chord }] };

    default:
      return { state, actions };
  }
}

function handleStart(state, frame) {
  const actions = [];
  const target = currentTarget(state, frame.target);
  const startAttempts = state.startAttempts + 1;
  const counted = { ...state, startAttempts };

  // Kolejność tych czterech gałęzi jest kontraktem §4.5.
  if (frame.target && frame.generation !== state.generation) {
    actions.push(error('windowGone', { message: 'Migawka okien jest nieaktualna.', target: frame.target }));
    replyWindows(state, actions);
    return { state: counted, actions };
  }
  if (!target) {
    actions.push(error('windowGone', { message: 'Docelowe okno już nie istnieje.', target: frame.target }));
    replyWindows(state, actions);
    return { state: counted, actions };
  }
  if (state.utterance) {
    actions.push(error('busy', { message: 'Mac jest już w trakcie wypowiedzi.', target: target.id }));
    return { state: counted, actions };
  }
  if (state.scenario === 'windowGone' && state.startAttempts === 0) {
    const removed = removeWindowState(counted, target.id).state;
    actions.push(error('windowGone', { message: 'Scenariusz usunął okno przed rozpoczęciem.', target: target.id }));
    replyWindows(removed, actions);
    return { state: removed, actions };
  }
  if (state.scenario === 'focusFailed' && state.startAttempts === 0) {
    actions.push(error('focusFailed', { message: 'Nie udało się podnieść docelowego okna.', target: target.id }));
    return { state: counted, actions };
  }
  if (state.scenario === 'busy') {
    actions.push(error('busy', { message: 'Scenariusz symuluje zajętą sesję.', target: target.id }));
    return { state: counted, actions };
  }

  const focused = focusWindowState(counted, target.id);
  stateChangeWindows(focused.state, actions, focused.changed);
  const phase = state.scenario === 'silent' ? 'silent' : 'arming';
  const next = { ...focused.state, utterance: { target: target.id, phase, previewIndex: -1, lastPreview: null } };
  if (phase === 'arming') actions.push({ kind: 'scheduleStarted', target: target.id });
  return { state: next, actions };
}

/** Wywoływane wyłącznie przez timer ustawiony na ścieżce sukcesu `start`. */
export function completeStarted(state, target) {
  if (state.utterance?.phase !== 'arming' || state.utterance.target !== target) return { state, actions: [] };
  return {
    state: { ...state, utterance: { ...state.utterance, phase: 'streaming' } },
    actions: [send({ type: 'started', target }), { kind: 'startPreview' }, ...(state.scenario === 'dropMidUtterance' ? [{ kind: 'dropLater' }] : [])],
  };
}

export function previewTick(state) {
  if (state.utterance?.phase !== 'streaming') return { state, actions: [] };
  const index = Math.min(state.utterance.previewIndex + 1, TRANSCRIPT_PHRASES.length - 1);
  const text = TRANSCRIPT_PHRASES[index];
  return {
    state: { ...state, utterance: { ...state.utterance, previewIndex: index, lastPreview: text } },
    actions: [send({ type: 'preview', text })],
  };
}

export function completeInjected(state, target) {
  if (state.utterance?.phase !== 'finishing' || state.utterance.target !== target) return { state, actions: [] };
  const window = findWindow(state, target);
  const text = state.utterance.lastPreview ?? TRANSCRIPT_PHRASES[0];
  return {
    state: { ...state, utterance: null },
    actions: [send({ type: 'injected', target, text, via: window?.kind === 'terminal' ? 'clipboard' : 'liveTyping' })],
  };
}

export function handleBinaryFrame(state, bytes) {
  return { state: withAudioBytes(state, bytes), actions: [] };
}

/** Odświeżenie warstwy 3: wysyła tylko gdy faktycznie dopisano nową linię. */
export function terminalTick(state) {
  const id = state.subscription.terminal;
  if (!id || !state.caps.terminalText || !isTerminalWindow(state, id)) return { state, actions: [] };
  const revision = state.terminal.revision + 1;
  const line = `  ⎿  macsim: Claude pracuje… krok ${revision}`;
  const lines = [...state.terminal.lines.slice(-29), line];
  const terminal = { seq: state.terminal.seq + 1, revision, lines };
  const next = { ...state, terminal };
  return {
    state: next,
    actions: [send({ type: 'terminal', id, generation: next.generation, seq: terminal.seq, lines: [...lines] })],
  };
}
