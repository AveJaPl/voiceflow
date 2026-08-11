import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RelayHub } from '../src/relayHub.js';

/** Fejkowy WebSocket — zero prawdziwej sieci, tylko interfejs, którego używa RelayHub. */
function fakeSocket() {
  return {
    readyState: 1, // OPEN
    sent: [],
    closed: null,
    send(data, opts) {
      this.sent.push({ data, opts });
    },
    close(code, reason) {
      this.readyState = 3; // CLOSED
      this.closed = { code, reason };
    },
  };
}

test('ramka binarna od phone leci 1:1 do mac (pass-through)', () => {
  const hub = new RelayHub();
  const mac = fakeSocket();
  const phone = fakeSocket();
  hub.register('mac', mac);
  hub.register('phone', phone);

  const audioChunk = Buffer.from([1, 2, 3, 4]);
  const delivered = hub.route('phone', audioChunk, true);

  assert.equal(delivered, true);
  assert.equal(mac.sent.length, 1);
  assert.equal(mac.sent[0].data, audioChunk);
  assert.equal(mac.sent[0].opts.binary, true);
  assert.equal(phone.sent.length, 0, 'phone nie powinien dostać echa własnej ramki');
});

test('ramka TEKSTOWA (np. status focusu, §5a planu) leci 1:1, bez zmiany na binarną', () => {
  // Weryfikacja z docs/plans/remote-mic-relay.md §5a, ostatni akapit: `route`
  // przekazuje `isBinary` wprost do `target.send(data, { binary: isBinary })`
  // bez żadnego rozgałęzienia na typ danych — ten sam kod ścieżki co ramka
  // audio wyżej, tylko z `isBinary=false`. Test istnieje, żeby to było
  // jawnie sprawdzone, nie tylko wywnioskowane z czytania kodu.
  const hub = new RelayHub();
  const mac = fakeSocket();
  const phone = fakeSocket();
  hub.register('mac', mac);
  hub.register('phone', phone);

  const focusFrame = JSON.stringify({ type: 'focus', app: 'Xcode', window: 'RemoteMicClient.swift' });
  const delivered = hub.route('mac', focusFrame, false);

  assert.equal(delivered, true);
  assert.equal(phone.sent.length, 1);
  assert.equal(phone.sent[0].data, focusFrame);
  assert.equal(phone.sent[0].opts.binary, false);
});

test('wiele ramek pod rząd — każda leci osobno, bez buforowania/łączenia', () => {
  const hub = new RelayHub();
  const mac = fakeSocket();
  hub.register('mac', mac);
  const phone = fakeSocket();
  hub.register('phone', phone);

  hub.route('phone', Buffer.from([1]), true);
  hub.route('phone', Buffer.from([2]), true);
  hub.route('phone', Buffer.from([3]), true);

  assert.equal(mac.sent.length, 3);
  assert.deepEqual(
    mac.sent.map((m) => [...m.data]),
    [[1], [2], [3]]
  );
});

test('phone dostaje jasny błąd, gdy mac nie jest połączony (przy rejestracji)', () => {
  const hub = new RelayHub();
  const phone = fakeSocket();

  hub.register('phone', phone);

  assert.equal(phone.sent.length, 1);
  const message = JSON.parse(phone.sent[0].data);
  assert.equal(message.type, 'error');
  assert.equal(message.code, 'mac_offline');
});

test('phone dostaje jasny błąd, gdy próbuje wysłać audio bez połączonego mac', () => {
  const hub = new RelayHub();
  const phone = fakeSocket();
  hub.register('phone', phone);
  phone.sent = []; // wyczyść błąd z samej rejestracji, testujemy błąd przy wysyłce

  const delivered = hub.route('phone', Buffer.from([9]), true);

  assert.equal(delivered, false);
  assert.equal(phone.sent.length, 1);
  const message = JSON.parse(phone.sent[0].data);
  assert.equal(message.code, 'mac_offline');
});

test('nowe połączenie mac zamyka stare (reconnect/nowe urządzenie)', () => {
  const hub = new RelayHub();
  const oldMac = fakeSocket();
  const newMac = fakeSocket();

  hub.register('mac', oldMac);
  hub.register('mac', newMac);

  assert.equal(oldMac.closed !== null, true);
  assert.equal(hub.sockets.mac, newMac);
});

test('rozłączenie mac nie zdejmuje nowszego połączenia zarejestrowanego pod tą samą rolą', () => {
  const hub = new RelayHub();
  const firstMac = fakeSocket();
  hub.register('mac', firstMac);

  const secondMac = fakeSocket();
  hub.register('mac', secondMac);

  // Spóźnione zdarzenie close od PIERWSZEGO socketu nie powinno skasować drugiego.
  hub.unregister('mac', firstMac);

  assert.equal(hub.sockets.mac, secondMac);
});

test('mac nie jest zaskoczony błędem — route od mac bez phone po prostu nic nie dostarcza', () => {
  const hub = new RelayHub();
  const mac = fakeSocket();
  hub.register('mac', mac);

  const delivered = hub.route('mac', Buffer.from([1]), true);

  assert.equal(delivered, false);
  assert.equal(mac.sent.length, 0, 'mac nie powinien dostać błędu zwrotnego do siebie samego');
});
