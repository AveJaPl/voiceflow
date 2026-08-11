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
  /** kod pokoju -> { state, connections:Set, roomId } */
  const rooms = new Map();

  function room(code) {
    if (!rooms.has(code)) {
      rooms.set(code, { state: createRoomState(), connections: new Set(), roomId: null });
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

  return {
    async handleMessage(connection, message, now = Date.now()) {
      const entry = room(connection.roomCode);
      if (connection.roomId) entry.roomId = connection.roomId;

      if (message.type === 'hello') {
        entry.connections.add(connection);
        entry.state = join(entry.state, connection.deviceId, connection.name);
        connection.send({ type: 'room_state', speaking: speakerPayload(entry) });
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
          const session = await store.activeSession(entry.roomId);
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
