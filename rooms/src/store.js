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

/**
 * Zamknięte i trwające sesje pokoju, z sumami każdej z nich.
 *
 * Sesja bez ani jednego dyktowania też tu jest: „zaczęliśmy i nic z tego nie
 * wyszło" to prawdziwy fakt o pracy, a ukrycie takiej sesji wyglądałoby na
 * zgubione dane.
 */
export function historyRows(rows) {
  return rows.map((row) => {
    const words = Number(row.words);
    const dictations = Number(row.dictations);
    return {
      id: Number(row.id),
      name: row.name,
      startedAt: row.started_at,
      endedAt: row.ended_at,
      words,
      seconds: Number(row.seconds),
      dictations,
      speakers: Number(row.speakers),
      averageWords: dictations > 0 ? Math.round(words / dictations) : 0,
    };
  });
}

/** Dorobek każdej osoby w pokoju przez WSZYSTKIE sesje, nie tylko bieżącą. */
export function summaryRows(rows) {
  return rows
    .map((row) => {
      const words = Number(row.words);
      const dictations = Number(row.dictations);
      return {
        deviceId: row.device_id,
        name: row.name,
        sessions: Number(row.sessions),
        words,
        seconds: Number(row.seconds),
        dictations,
        averageWords: dictations > 0 ? Math.round(words / dictations) : 0,
      };
    })
    .sort((a, b) => b.words - a.words);
}

/**
 * Sumy całego pokoju — jedna liczba na wiersz tablicy „razem".
 *
 * `sessionCount` przychodzi osobno, a nie z długości listy: lista jest jedną
 * stroną wyników, więc liczenie jej wierszy pokazywałoby „20 sesji" w pokoju,
 * który ma ich sto.
 */
export function historyTotals(sessionCount, people) {
  return {
    sessions: sessionCount,
    people: people.length,
    words: people.reduce((total, person) => total + person.words, 0),
    seconds: people.reduce((total, person) => total + person.seconds, 0),
    dictations: people.reduce((total, person) => total + person.dictations, 0),
  };
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

    /**
     * Historia sesji pokoju, od najnowszej. LEFT JOIN, żeby sesja bez ani
     * jednego dyktowania nie wypadła z listy.
     */
    async sessionHistory(roomId, limit = 20, offset = 0) {
      const { rows } = await pool.query(
        `SELECT s.id, s.name, s.started_at, s.ended_at,
                COALESCE(SUM(d.words), 0)          AS words,
                COALESCE(SUM(d.seconds), 0)        AS seconds,
                COUNT(d.id)                        AS dictations,
                COUNT(DISTINCT d.device_id)        AS speakers
         FROM sessions s
         LEFT JOIN dictations d ON d.session_id = s.id
         WHERE s.room_id = $1
         GROUP BY s.id
         ORDER BY s.started_at DESC
         LIMIT $2 OFFSET $3`,
        // Bierzemy o jeden wiersz za dużo: to najtańszy sposób, żeby wiedzieć,
        // czy jest co dociągać, bez drugiego zapytania liczącego wszystko.
        [roomId, limit + 1, offset],
      );
      return historyRows(rows);
    },

    /** Ile sesji miał ten pokój w całości — niezależnie od strony wyników. */
    async sessionCount(roomId) {
      const { rows } = await pool.query(
        'SELECT COUNT(*) AS total FROM sessions WHERE room_id = $1',
        [roomId],
      );
      return Number(rows[0]?.total ?? 0);
    },

    /** Dorobek każdej osoby przez wszystkie sesje tego pokoju. */
    async roomSummary(roomId) {
      const { rows } = await pool.query(
        `SELECT d.device_id, dev.name,
                COUNT(DISTINCT d.session_id) AS sessions,
                COALESCE(SUM(d.words), 0)    AS words,
                COALESCE(SUM(d.seconds), 0)  AS seconds,
                COUNT(*)                     AS dictations
         FROM dictations d
         JOIN devices dev ON dev.id = d.device_id
         JOIN sessions s  ON s.id = d.session_id
         WHERE s.room_id = $1
         GROUP BY d.device_id, dev.name`,
        [roomId],
      );
      return summaryRows(rows);
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
