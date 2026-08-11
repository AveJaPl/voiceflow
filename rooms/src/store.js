/**
 * Jedyne miejsce w usłudze, które zna SQL.
 *
 * Czyste przeliczenia (`rankingRows`, `generateCode`, `hashToken`) są wyciągnięte
 * osobno i eksportowane, żeby dało się je przetestować bez bazy — reszta to
 * cienkie opakowania na zapytania.
 */

import { randomUUID, randomBytes, createHash } from 'node:crypto';

/** Bez 0/O i 1/I/L — kod bywa przepisywany z ekranu na ekran. */
const CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export function generateCode() {
  const bytes = randomBytes(6);
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
}

/** Token urządzenia trafia do bazy wyłącznie jako hash. */
export function hashToken(token) {
  return createHash('sha256').update(token).digest('hex');
}

/**
 * Wiersze z SQL na to, co widzi strona.
 *
 * `Number()` nie jest kosmetyką: pg oddaje BIGINT i SUM jako tekst, a sortowanie
 * po tekście postawiłoby "90" przed "120".
 */
export function rankingRows(rows) {
  return rows
    .map((row) => {
      const words = Number(row.words);
      const dictations = Number(row.dictations);
      return {
        deviceId: row.device_id,
        name: row.name,
        words,
        seconds: Number(row.seconds),
        dictations,
        averageWords: dictations > 0 ? Math.round(words / dictations) : 0,
      };
    })
    .sort((a, b) => b.words - a.words);
}

export function createStore(pool) {
  return {
    async registerDevice(name, platform) {
      const id = randomUUID();
      const token = randomBytes(32).toString('base64url');
      await pool.query(
        'INSERT INTO devices (id, name, token_hash, platform) VALUES ($1, $2, $3, $4)',
        [id, name, hashToken(token), platform ?? null],
      );
      return { id, token, name };
    },

    async deviceByToken(token) {
      if (!token) return null;
      const { rows } = await pool.query(
        'SELECT id, name FROM devices WHERE token_hash = $1',
        [hashToken(token)],
      );
      return rows[0] ?? null;
    },

    async touchDevice(deviceId) {
      await pool.query('UPDATE devices SET last_seen = now() WHERE id = $1', [deviceId]);
    },

    async createRoom(name) {
      const code = generateCode();
      const { rows } = await pool.query(
        'INSERT INTO rooms (code, name) VALUES ($1, $2) RETURNING id, code, name',
        [code, name ?? null],
      );
      return rows[0];
    },

    async roomByCode(code) {
      const { rows } = await pool.query(
        'SELECT id, code, name FROM rooms WHERE code = $1',
        [String(code).toUpperCase()],
      );
      return rows[0] ?? null;
    },

    async joinRoom(roomId, deviceId) {
      await pool.query(
        `INSERT INTO room_members (room_id, device_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING`,
        [roomId, deviceId],
      );
    },

    async members(roomId) {
      const { rows } = await pool.query(
        `SELECT d.id, d.name FROM room_members m
         JOIN devices d ON d.id = m.device_id
         WHERE m.room_id = $1 ORDER BY m.joined_at`,
        [roomId],
      );
      return rows;
    },

    async startSession(roomId, name) {
      const { rows } = await pool.query(
        'INSERT INTO sessions (room_id, name) VALUES ($1, $2) RETURNING id, name, started_at',
        [roomId, name ?? null],
      );
      return rows[0];
    },

    async activeSession(roomId) {
      const { rows } = await pool.query(
        `SELECT id, name, started_at FROM sessions
         WHERE room_id = $1 AND ended_at IS NULL
         ORDER BY started_at DESC LIMIT 1`,
        [roomId],
      );
      return rows[0] ?? null;
    },

    async endSession(sessionId) {
      await pool.query('UPDATE sessions SET ended_at = now() WHERE id = $1', [sessionId]);
    },

    async renameSession(sessionId, name) {
      await pool.query('UPDATE sessions SET name = $2 WHERE id = $1', [sessionId, name]);
    },

    async recordDictation(sessionId, deviceId, at, seconds, words) {
      await pool.query(
        `INSERT INTO dictations (session_id, device_id, at, seconds, words)
         VALUES ($1, $2, $3, $4, $5)`,
        [sessionId, deviceId, new Date(at), seconds, words],
      );
    },

    async ranking(sessionId) {
      const { rows } = await pool.query(
        `SELECT d.device_id, dev.name,
                COALESCE(SUM(d.words), 0)   AS words,
                COALESCE(SUM(d.seconds), 0) AS seconds,
                COUNT(*)                    AS dictations
         FROM dictations d
         JOIN devices dev ON dev.id = d.device_id
         WHERE d.session_id = $1
         GROUP BY d.device_id, dev.name`,
        [sessionId],
      );
      return rankingRows(rows);
    },
  };
}
