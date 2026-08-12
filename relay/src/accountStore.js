import { randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import Database from 'better-sqlite3';
import bcrypt from 'bcryptjs';

const BCRYPT_ROUNDS = 10;

/**
 * Konta + log sesji w SQLite. Konto ma JEDEN stały token parowania
 * (`pair_token`) — telefon i Mac logują się raz i dostają ten sam token,
 * zamiast ręcznie przepisywać token z `POST /pair`. Stary mechanizm
 * `PairingStore` zostaje nietknięty (zgodność wsteczna).
 */
export class AccountStore {
  constructor(filePath) {
    if (filePath !== ':memory:') mkdirSync(dirname(filePath), { recursive: true });
    this.db = new Database(filePath);
    this.db.pragma('journal_mode = WAL');
    this._migrate();
  }

  _migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS accounts (
        id INTEGER PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        pair_token TEXT NOT NULL UNIQUE,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE TABLE IF NOT EXISTS session_log (
        id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES accounts(id),
        role TEXT NOT NULL,
        device TEXT,
        event TEXT NOT NULL,
        at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_session_log_at ON session_log(at DESC);
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES accounts(id),
        created_at DATETIME NOT NULL,
        text TEXT NOT NULL,
        duration_seconds REAL NOT NULL DEFAULT 0,
        target TEXT,
        source TEXT NOT NULL DEFAULT 'mac'
      );
      CREATE INDEX IF NOT EXISTS idx_history_account_created
        ON history(account_id, created_at DESC);
    `);
  }

  /** Tworzy konto ze stałym tokenem parowania. Rzuca Error('email_taken') przy duplikacie. */
  register(email, password) {
    const pairToken = randomBytes(32).toString('base64url');
    const passwordHash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
    try {
      const info = this.db
        .prepare('INSERT INTO accounts (email, password_hash, pair_token) VALUES (?, ?, ?)')
        .run(email.trim().toLowerCase(), passwordHash, pairToken);
      return { id: info.lastInsertRowid, email, pairToken };
    } catch (err) {
      if (err.code === 'SQLITE_CONSTRAINT_UNIQUE') throw new Error('email_taken');
      throw err;
    }
  }

  /** Zwraca stały pairToken konta albo null przy złym mailu/haśle. */
  login(email, password) {
    const row = this.db
      .prepare('SELECT password_hash, pair_token FROM accounts WHERE email = ?')
      .get(String(email).trim().toLowerCase());
    if (!row) return null;
    if (!bcrypt.compareSync(password, row.password_hash)) return null;
    return row.pair_token;
  }

  findByPairToken(token) {
    if (!token) return null;
    return this.db.prepare('SELECT id, email FROM accounts WHERE pair_token = ?').get(token) || null;
  }

  /** Zapisuje wpis connected/disconnected; zwraca id wiersza (do późniejszego uzupełnienia device). */
  logEvent({ accountId, role, event, device = null }) {
    const info = this.db
      .prepare('INSERT INTO session_log (account_id, role, device, event) VALUES (?, ?, ?, ?)')
      .run(accountId, role, device, event);
    return info.lastInsertRowid;
  }

  /** Uzupełnia nazwę urządzenia, gdy dojdzie ramka `hello` (przy connect jej jeszcze nie znamy). */
  setDevice(sessionLogId, device) {
    this.db.prepare('UPDATE session_log SET device = ? WHERE id = ?').run(device, sessionLogId);
  }

  recentSessions(limit = 50) {
    return this.db
      .prepare(
        `SELECT s.id, s.account_id, a.email, s.role, s.device, s.event, s.at
         FROM session_log s JOIN accounts a ON a.id = s.account_id
         ORDER BY s.id DESC LIMIT ?`
      )
      .all(limit);
  }

  /**
   * Dopisuje wpis historii dyktowania. `createdAt` trzymamy jako znormalizowany
   * ISO-8601 UTC, żeby porównanie tekstowe (paginacja `before`) było zgodne
   * z porządkiem chronologicznym.
   */
  addHistoryEntry({ accountId, text, createdAt, durationSeconds = 0, target = null, source = 'mac' }) {
    const info = this.db
      .prepare(
        `INSERT INTO history (account_id, created_at, text, duration_seconds, target, source)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(accountId, createdAt, text, durationSeconds, target, source);
    return info.lastInsertRowid;
  }

  /** Wpisy konta od najnowszego; `before` (ISO) przewija na starsze. */
  historyEntries({ accountId, limit = 100, before = null }) {
    const rows = before
      ? this.db
          .prepare(
            `SELECT id, created_at, text, duration_seconds, target, source FROM history
             WHERE account_id = ? AND created_at < ?
             ORDER BY created_at DESC, id DESC LIMIT ?`
          )
          .all(accountId, before, limit)
      : this.db
          .prepare(
            `SELECT id, created_at, text, duration_seconds, target, source FROM history
             WHERE account_id = ?
             ORDER BY created_at DESC, id DESC LIMIT ?`
          )
          .all(accountId, limit);
    return rows.map((row) => ({
      id: row.id,
      createdAt: row.created_at,
      text: row.text,
      durationSeconds: row.duration_seconds,
      target: row.target,
      source: row.source,
    }));
  }

  /** Kasuje wpis wyłącznie z własnego konta; false = nie ma takiego wpisu u tego konta. */
  deleteHistoryEntry({ accountId, id }) {
    const info = this.db.prepare('DELETE FROM history WHERE id = ? AND account_id = ?').run(id, accountId);
    return info.changes > 0;
  }

  close() {
    this.db.close();
  }
}
