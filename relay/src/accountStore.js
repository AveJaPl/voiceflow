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

  close() {
    this.db.close();
  }
}
