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

/**
 * Tryby pokoju — jedna rzecz, którą pokój wie o świecie poza ekranem.
 *
 * `together`: wszyscy siedzą w jednym pomieszczeniu. Mikrofon jest jeden na
 * wszystkich, bo dwie osoby mówiące naraz nagrywają się nawzajem i psują obie
 * transkrypcje.
 *
 * `remote`: każdy siedzi gdzie indziej. Nikt nikomu nie wchodzi w mikrofon,
 * więc kolejka do niego byłaby czystą przeszkodą — pokój zostaje wspólną
 * tablicą (ranking, wykresy, kto właśnie dyktuje), a nie blokadą.
 */
export const MODES = ['together', 'remote'];
export const DEFAULT_MODE = 'together';

export function isMode(value) {
  return MODES.includes(value);
}

export function createRoomState() {
  // `speakers` to mapa, a nie jeden slot: w trybie zdalnym mówiących naraz
  // może być tylu, ile osób w pokoju, i każde z tych dyktowań ma trafić do
  // statystyk jako osobne.
  return { members: {}, speakers: {}, pending: [] };
}

export function join(state, deviceId, name) {
  return { ...state, members: { ...state.members, [deviceId]: { name } } };
}

export function leave(state, deviceId) {
  const members = { ...state.members };
  delete members[deviceId];
  return { ...state, members, speakers: without(state.speakers, deviceId) };
}

/**
 * Zwraca `{state, accepted, blockedBy}`. Odmowa NIE zmienia stanu mówiącego —
 * próba wejścia w słowo nie może skrócić cudzej wypowiedzi.
 *
 * `exclusive` wyłącza samą odmowę, nie ewidencję: w trybie zdalnym wszyscy
 * mówiący są zapisani tak samo, tylko nikt nikogo nie blokuje.
 */
export function startSpeaking(state, deviceId, now, { exclusive = true } = {}) {
  if (!state.members[deviceId]) {
    return { state, accepted: false, blockedBy: null };
  }
  if (exclusive) {
    const other = Object.keys(state.speakers).find((id) => id !== deviceId);
    if (other) {
      return { state, accepted: false, blockedBy: state.members[other]?.name ?? null };
    }
  }
  return {
    state: {
      ...state,
      speakers: { ...state.speakers, [deviceId]: { since: now, lastSeen: now } },
    },
    accepted: true,
    blockedBy: null,
  };
}

export function stopSpeaking(state, deviceId, now, { words, seconds }) {
  if (!state.speakers[deviceId]) return state;
  return {
    ...state,
    speakers: without(state.speakers, deviceId),
    pending: [...state.pending, { deviceId, words, seconds, at: now }],
  };
}

export function heartbeat(state, deviceId, now) {
  const speaking = state.speakers[deviceId];
  if (!speaking) return state;
  return {
    ...state,
    speakers: { ...state.speakers, [deviceId]: { ...speaking, lastSeen: now } },
  };
}

/** Zdejmuje blokadę po mówiących, którzy przestali dawać znaki życia. */
export function expire(state, now) {
  const alive = {};
  for (const [deviceId, speaking] of Object.entries(state.speakers)) {
    if (now - speaking.lastSeen <= HEARTBEAT_TIMEOUT_MS) alive[deviceId] = speaking;
  }
  if (Object.keys(alive).length === Object.keys(state.speakers).length) return state;
  return { ...state, speakers: alive };
}

/**
 * Kto mówi, od najdawniej mówiącego. Kolejność jest stabilna, bo tablica
 * rysuje z tego listę — a lista skacząca przy każdym odświeżeniu wygląda jak
 * usterka.
 */
export function speakerList(state) {
  return Object.entries(state.speakers)
    .map(([deviceId, speaking]) => ({
      deviceId,
      name: state.members[deviceId]?.name ?? null,
      since: speaking.since,
    }))
    .sort((a, b) => a.since - b.since);
}

/** Zdarzenia gotowe do zapisania; wywołujący czyści je po udanym zapisie. */
export function drainPending(state) {
  return [{ ...state, pending: [] }, state.pending];
}

function without(map, key) {
  const copy = { ...map };
  delete copy[key];
  return copy;
}
