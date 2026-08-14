/**
 * Obecność w pokoju po WebSockecie: kto dołączył, kto mówi, kto skończył.
 *
 * Reguły „kto może mówić" nie mieszkają tutaj — są w `roomState.js` jako czyste
 * funkcje. Tutaj jest tylko rozdzielanie komunikatów, rozgłaszanie i zapis
 * liczb do bazy.
 */

import {
  createRoomState, join, leave, startSpeaking, stopSpeaking, heartbeat, expire,
} from './roomState.js';

export function createHub({ store }) {
  /** kod pokoju -> { state, connections:Set, roomId, nowPlaying:Map } */
  const rooms = new Map();

  function room(code) {
    if (!rooms.has(code)) {
      rooms.set(code, {
        state: createRoomState(),
        connections: new Set(),
        roomId: null,
        // Wyłącznie w pamięci procesu: restart usługi kasuje kafelki i to
        // jest w porządku — to stan chwili, nie dane.
        nowPlaying: new Map(),
        usage: new Map(),
      });
    }
    return rooms.get(code);
  }

  function speakerPayload(entry) {
    const speaking = entry.state.speaking;
    if (!speaking) return null;
    return {
      deviceId: speaking.deviceId,
      name: entry.state.members[speaking.deviceId]?.name ?? null,
      since: speaking.since,
    };
  }

  /**
   * Rozgłasza, kto mówi — z pominięciem samego mówiącego.
   *
   * To pominięcie jest istotne, nie kosmetyczne: mówiącemu dźwięk ścisza jego
   * własny skrót, a drugie ściszenie tą drogą zapisałoby już ściszoną głośność
   * jako „oryginalną" i po przywróceniu zostawiłoby go cicho na stałe.
   */
  function broadcastSpeaker(code, exceptDeviceId) {
    const entry = room(code);
    const payload = { type: 'speaker_changed', speaking: speakerPayload(entry) };
    for (const connection of entry.connections) {
      if (connection.deviceId === exceptDeviceId) continue;
      connection.send(payload);
    }
  }

  /** Kto co słuchał — tylko w pamięci procesu, nigdy w bazie. */
  function nowPlayingPayload(entry) {
    const playing = [];
    for (const [deviceId, item] of entry.nowPlaying) {
      if (item.track) playing.push({ deviceId, name: item.name, ...item.track });
    }
    return { type: 'now_playing', playing };
  }

  function usagePayload(entry) {
    const people = [];
    for (const [deviceId, item] of entry.usage) {
      if (item.usage) people.push({ deviceId, name: item.name, ...item.usage });
    }
    return { type: 'claude_usage', people };
  }

  function broadcastUsage(code) {
    const entry = room(code);
    const payload = usagePayload(entry);
    for (const connection of entry.connections) connection.send(payload);
  }

  function broadcastNowPlaying(code) {
    const entry = room(code);
    const payload = nowPlayingPayload(entry);
    for (const connection of entry.connections) connection.send(payload);
  }

  return {
    async handleMessage(connection, message, now = Date.now()) {
      const entry = room(connection.roomCode);
      if (connection.roomId) entry.roomId = connection.roomId;

      if (message.type === 'hello') {
        entry.connections.add(connection);
        // Widz (strona rankingu) dostaje rozgłoszenia, ale NIE wchodzi do składu
        // pokoju: nie może mówić, nie może niczego zablokować i nie liczy się do
        // rankingu. Patrzy.
        if (!connection.viewer) {
          entry.state = join(entry.state, connection.deviceId, connection.name);
        }
        connection.send({ type: 'room_state', speaking: speakerPayload(entry) });
        connection.send(nowPlayingPayload(entry));
        connection.send(usagePayload(entry));
        return;
      }

      if (connection.viewer) return;

      if (message.type === 'now_playing') {
        // Przelotem: rozsyłamy i zapominamy. Nie ma na to tabeli ani kolumny
        // i mieć nie będzie — zamknięcie sesji nie zostawia śladu tego, czego
        // kto słuchał. Ta sama zasada, dla której `dictations` nie trzyma tekstu.
        const track = message.track ? {
          title: String(message.track.title ?? '').slice(0, 200),
          artist: String(message.track.artist ?? '').slice(0, 200),
          player: String(message.track.player ?? '').slice(0, 80),
          artUrl: String(message.track.artUrl ?? '').slice(0, 500),
        } : null;
        entry.nowPlaying.set(connection.deviceId, { name: connection.name, track });
        broadcastNowPlaying(connection.roomCode);
        return;
      }

      if (message.type === 'claude_usage') {
        // Jak muzyka: przelotem, bez tabeli. Klient może dzielenie się tym
        // wyłączyć u siebie — tu tylko rozsyłamy to, co przyszło.
        // null w procentach to „ta maszyna nie zna swoich limitów" (brak
        // snapshotu paska statusu na Windowsie/macOS) — 0% byłoby zmyśleniem.
        const pct = (value) => value == null
          ? null
          : Math.max(0, Math.min(100, Number(value) || 0));
        const usage = message.usage ? {
          fiveHour: pct(message.usage.fiveHour),
          sevenDay: pct(message.usage.sevenDay),
          resetsAt: Number(message.usage.resetsAt) || 0,
          tokensIn: Math.max(0, Math.floor(Number(message.usage.tokensIn) || 0)),
          tokensOut: Math.max(0, Math.floor(Number(message.usage.tokensOut) || 0)),
        } : null;
        entry.usage.set(connection.deviceId, { name: connection.name, usage });
        broadcastUsage(connection.roomCode);
        return;
      }

      if (message.type === 'heartbeat') {
        entry.state = heartbeat(entry.state, connection.deviceId, now);
        return;
      }

      if (message.type === 'speaking_started') {
        const result = startSpeaking(entry.state, connection.deviceId, now);
        entry.state = result.state;
        if (!result.accepted) {
          connection.send({ type: 'speaking_denied', blockedBy: result.blockedBy });
          return;
        }
        broadcastSpeaker(connection.roomCode, connection.deviceId);
        return;
      }

      if (message.type === 'speaking_ended') {
        entry.state = stopSpeaking(entry.state, connection.deviceId, now, {
          words: message.words ?? 0,
          seconds: message.seconds ?? 0,
        });
        // Najpierw zwolnij głos, potem zapisuj. Kolejność jest celowa: gdyby
        // zapis się wysypał przed rozgłoszeniem, pokój zostałby zablokowany
        // przez statystykę, która nikomu nie jest potrzebna do mówienia.
        broadcastSpeaker(connection.roomCode, connection.deviceId);
        entry.state = { ...entry.state, pending: [] };

        try {
          // Zero słów to anulowanie albo cisza — głos zwalniamy, ale wpisu nie
          // tworzymy: pusty rekord zaniżałby średnią długość dyktowania i
          // zaśmiecał ranking zdarzeniami, w których nikt nic nie powiedział.
          const worthRecording = (message.words ?? 0) > 0;
          const session = worthRecording ? await store.activeSession(entry.roomId) : null;
          if (session) {
            await store.recordDictation(
              session.id, connection.deviceId, now,
              message.seconds ?? 0, message.words ?? 0,
            );
          }
        } catch (error) {
          console.error('[rooms] nie zapisano dyktowania:', error.message);
        }
        return;
      }
    },

    disconnect(connection) {
      const entry = room(connection.roomCode);
      entry.connections.delete(connection);
      if (entry.nowPlaying.delete(connection.deviceId)) {
        broadcastNowPlaying(connection.roomCode);
      }
      if (entry.usage.delete(connection.deviceId)) {
        broadcastUsage(connection.roomCode);
      }
      const wasSpeaking = entry.state.speaking?.deviceId === connection.deviceId;
      entry.state = leave(entry.state, connection.deviceId);
      if (wasSpeaking) broadcastSpeaker(connection.roomCode, null);
    },

    /** Sprząta po klientach, którzy zniknęli w trakcie mówienia. */
    tick(now = Date.now()) {
      for (const [code, entry] of rooms) {
        const before = entry.state.speaking?.deviceId ?? null;
        entry.state = expire(entry.state, now);
        const after = entry.state.speaking?.deviceId ?? null;
        if (before !== after) broadcastSpeaker(code, null);
      }
    },
  };
}
