const OPEN = 1; // WebSocket.OPEN — trzymane jako stała, żeby ten moduł nie zależał od `ws`.

/**
 * Łączy DOKŁADNIE JEDNĄ sparowaną parę "mac" (trwały odbiorca) i "phone"
 * (nadawca audio). Czysty pass-through: każda ramka od phone leci 1:1 do mac,
 * zero buforowania, zero dekodowania, zero zapisu na dysk. Gdy mac nie jest
 * połączony, phone dostaje jasny błąd zamiast ciszy.
 *
 * Celowo bez importu `ws` — testowalne fejkowymi obiektami socketów
 * ({ send(data, opts), close(code, reason), readyState }).
 */
export class RelayHub {
  constructor() {
    this.sockets = { mac: null, phone: null };
  }

  /** Rejestruje socket pod rolą; jeśli była już aktywna, zamyka starą (reconnect/nowe urządzenie). */
  register(role, socket) {
    const previous = this.sockets[role];
    if (previous && previous !== socket && previous.readyState === OPEN) {
      previous.close(4000, 'replaced-by-new-connection');
    }
    this.sockets[role] = socket;

    if (role === 'phone') {
      this._notifyIfMacOffline(socket);
    }
  }

  /** Wypina socket, ale tylko jeśli to wciąż ten sam (nie kasuje nowszego połączenia). */
  unregister(role, socket) {
    if (this.sockets[role] === socket) {
      this.sockets[role] = null;
    }
  }

  /**
   * Przekazuje jedną ramkę od `role` do drugiej strony. Zwraca true, jeśli
   * dostarczono, false jeśli cel jest niedostępny (i wtedy — dla "phone" —
   * wysyła błąd zwrotny).
   */
  route(role, data, isBinary) {
    const target = role === 'phone' ? this.sockets.mac : this.sockets.phone;
    if (!target || target.readyState !== OPEN) {
      if (role === 'phone') {
        this._sendError(this.sockets.phone, 'mac_offline', 'Mac nie jest połączony z relayem.');
      }
      return false;
    }
    target.send(data, { binary: isBinary });
    return true;
  }

  _notifyIfMacOffline(phoneSocket) {
    if (!this.sockets.mac || this.sockets.mac.readyState !== OPEN) {
      this._sendError(phoneSocket, 'mac_offline', 'Mac nie jest połączony z relayem.');
    }
  }

  _sendError(socket, code, message) {
    if (!socket || socket.readyState !== OPEN) return;
    socket.send(JSON.stringify({ type: 'error', code, message }));
  }
}
