import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

/**
 * Trzyma DOKŁADNIE JEDEN aktywny token parowania (jedna para urządzeń, zgodnie
 * z planem — YAGNI, żadnej obsługi wielu par). Token jest zapisany na dysku
 * z znacznikiem czasu, żeby przetrwał restart procesu/kontenera; każde nowe
 * `generate()` bezwarunkowo unieważnia poprzedni token.
 */
export class PairingStore {
  constructor(filePath) {
    this.filePath = filePath;
    this._data = this._load();
  }

  _load() {
    if (!existsSync(this.filePath)) return null;
    try {
      return JSON.parse(readFileSync(this.filePath, 'utf8'));
    } catch {
      // Plik uszkodzony/pusty — traktuj jak brak aktywnego tokenu, nie wywalaj startu.
      return null;
    }
  }

  _save() {
    mkdirSync(dirname(this.filePath), { recursive: true });
    writeFileSync(this.filePath, JSON.stringify(this._data, null, 2));
  }

  /** Generuje nowy token i unieważnia poprzedni. Zwraca { token, createdAt }. */
  generate() {
    this._data = {
      token: randomBytes(32).toString('base64url'),
      createdAt: new Date().toISOString(),
    };
    this._save();
    return this._data;
  }

  isValid(token) {
    return Boolean(token) && Boolean(this._data) && token === this._data.token;
  }

  current() {
    return this._data;
  }
}
