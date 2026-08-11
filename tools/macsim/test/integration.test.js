import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { register } from 'node:module';
import { WebSocket } from 'ws';
import { MacSimSession } from '../src/session.js';

register(new URL('./relay-loader.js', import.meta.url));

function openSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

function frameQueue(ws) {
  const queued = [];
  const waiters = [];
  ws.on('message', (data, isBinary) => {
    const item = isBinary ? { binary: true, data } : { binary: false, frame: JSON.parse(data.toString()) };
    const index = waiters.findIndex((waiter) => waiter(item));
    // `splice` zwraca TABLICĘ usuniętych elementów, nie element — bez `[0]`
    // leci `waiters.splice(...).resolve is not a function` i test wywala się
    // na własnym rusztowaniu, zanim sprawdzi cokolwiek z macsim.
    if (index >= 0) waiters.splice(index, 1)[0].resolve(item);
    else queued.push(item);
  });
  return {
    next(predicate, timeoutMs = 1000) {
      const index = queued.findIndex(predicate);
      if (index >= 0) return Promise.resolve(queued.splice(index, 1)[0]);
      return new Promise((resolve, reject) => {
        const waiter = Object.assign((item) => predicate(item), { resolve });
        waiters.push(waiter);
        setTimeout(() => {
          const position = waiters.indexOf(waiter);
          if (position >= 0) waiters.splice(position, 1);
          reject(new Error('Timeout oczekiwania na ramkę relay/macsim.'));
        }, timeoutMs);
      });
    },
  };
}

test('loopback: hello → subscribe → focusWindow → start → audio → end → injected', async (t) => {
  const { createRelayServer } = await import('../../../relay/src/createServer.js');
  const { PairingStore } = await import('../../../relay/src/pairingStore.js');
  const directory = mkdtempSync(join(tmpdir(), 'voiceflow-macsim-test-'));
  const pairingStore = new PairingStore(join(directory, 'pairing.json'));
  const { token } = pairingStore.generate();
  const server = createRelayServer({ adminSecret: 'test-secret', pairingStore });
  let mac;
  let phone;
  let session;

  t.after(async () => {
    session?.dispose();
    mac?.close();
    phone?.close();
    await new Promise((resolve) => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  });

  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => {
        server.off('error', reject);
        resolve();
      });
    });
  } catch (error) {
    if (error?.code === 'EPERM') {
      t.skip('Piaskownica nie zezwala na bind 127.0.0.1; poza nią test wykonuje pełny loopback.');
      return;
    }
    throw error;
  }
  const port = server.address().port;
  const base = `ws://127.0.0.1:${port}/ws?token=${token}`;
  mac = await openSocket(`${base}&role=mac`);
  session = new MacSimSession({
    sendText: (text) => mac.send(text),
    sendBinary: (data) => mac.send(data, { binary: true }),
    close: (code, reason) => mac.close(code, reason),
    delays: { started: 10, preview: 15, injected: 10 },
  });
  mac.on('message', (data, isBinary) => {
    if (isBinary) session.receiveBinary(data);
    else session.receiveText(data.toString());
  });
  phone = await openSocket(`${base}&role=phone`);
  const received = frameQueue(phone);

  phone.send(JSON.stringify({ type: 'hello', protocol: 1, device: 'integration-phone' }));
  const hello = await received.next((item) => item.frame?.type === 'hello');
  assert.equal(hello.frame.mac, 'macsim');

  phone.send(JSON.stringify({ type: 'subscribe', windows: true, screenshot: false, terminal: null }));
  const initial = await received.next((item) => item.frame?.type === 'windows');
  const target = initial.frame.windows.find((window) => window.kind === 'terminal');

  phone.send(JSON.stringify({ type: 'focusWindow', id: target.id, generation: initial.frame.generation }));
  const focus = await received.next((item) => item.frame?.type === 'focus');
  assert.equal(focus.frame.app, 'Terminal');

  phone.send(JSON.stringify({ type: 'start', target: target.id, generation: initial.frame.generation }));
  const started = await received.next((item) => item.frame?.type === 'started');
  assert.equal(started.frame.target, target.id);
  phone.send(Buffer.from([1, 0, 2, 0]), { binary: true });
  const preview = await received.next((item) => item.frame?.type === 'preview');
  phone.send(JSON.stringify({ type: 'end' }));
  const injected = await received.next((item) => item.frame?.type === 'injected');

  assert.equal(injected.frame.target, target.id);
  assert.equal(injected.frame.text, preview.frame.text);
  assert.equal(injected.frame.via, 'clipboard');
  assert.equal(session.state.audio.acceptedBytes, 4);
});
