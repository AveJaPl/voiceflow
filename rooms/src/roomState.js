/**
 * Reguły pokoju jako czyste funkcje: kto może mówić, kiedy blokada wygasa,
 * co trafi do bazy. Ani bazy, ani gniazd — dzięki temu to, co najłatwiej
 * zepsuć, testuje się bez uruchamiania czegokolwiek.
 *
 * Każda funkcja zwraca NOWY stan. Nic nie mutuje w miejscu, więc test może
 * trzymać stan sprzed i po, i porównać je bez kopiowania.
 */

/**
 * Po tylu milisekundach bez pulsu uznajemy, że mówiący zniknął.
 *
 * To nie jest obejście twardej blokady — to definicja końca mówienia dla
 * klienta, którego już nie ma. Bez tego jeden zawieszony laptop blokuje pokój
 * wszystkim pozostałym bezterminowo, a to nie jest decyzja projektowa, tylko
 * usterka.
 */
export const HEARTBEAT_TIMEOUT_MS = 10_000;

export function createRoomState() {
  return { members: {}, speaking: null, pending: [] };
}

export function join(state, deviceId, name) {
  return { ...state, members: { ...state.members, [deviceId]: { name } } };
}

export function leave(state, deviceId) {
  const members = { ...state.members };
  delete members[deviceId];
  const speaking = state.speaking?.deviceId === deviceId ? null : state.speaking;
  return { ...state, members, speaking };
}

/**
 * Zwraca `{state, accepted, blockedBy}`. Odmowa NIE zmienia stanu mówiącego —
 * próba wejścia w słowo nie może skrócić cudzej wypowiedzi.
 */
export function startSpeaking(state, deviceId, now) {
  if (!state.members[deviceId]) {
    return { state, accepted: false, blockedBy: null };
  }
  if (state.speaking && state.speaking.deviceId !== deviceId) {
    const blockedBy = state.members[state.speaking.deviceId]?.name ?? null;
    return { state, accepted: false, blockedBy };
  }
  return {
    state: { ...state, speaking: { deviceId, since: now, lastSeen: now } },
    accepted: true,
    blockedBy: null,
  };
}

export function stopSpeaking(state, deviceId, now, { words, seconds }) {
  if (state.speaking?.deviceId !== deviceId) return state;
  return {
    ...state,
    speaking: null,
    pending: [...state.pending, { deviceId, words, seconds, at: now }],
  };
}

export function heartbeat(state, deviceId, now) {
  if (state.speaking?.deviceId !== deviceId) return state;
  return { ...state, speaking: { ...state.speaking, lastSeen: now } };
}

/** Zdejmuje blokadę po mówiącym, który przestał dawać znaki życia. */
export function expire(state, now) {
  if (!state.speaking) return state;
  if (now - state.speaking.lastSeen <= HEARTBEAT_TIMEOUT_MS) return state;
  return { ...state, speaking: null };
}

/** Zdarzenia gotowe do zapisania; wywołujący czyści je po udanym zapisie. */
export function drainPending(state) {
  return [{ ...state, pending: [] }, state.pending];
}
