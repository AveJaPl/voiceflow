import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MacSimSession } from '../src/session.js';

test('screenshot header bezpośrednio poprzedza jedną binarną ramkę JPEG', () => {
  const sent = [];
  const session = new MacSimSession({
    sendText: (text) => sent.push({ kind: 'text', frame: JSON.parse(text) }),
    sendBinary: (data) => sent.push({ kind: 'binary', data }),
  });

  session.receiveText(JSON.stringify({ type: 'requestScreenshot' }));
  session.dispose();

  assert.equal(sent.length, 2);
  assert.equal(sent[0].kind, 'text');
  assert.equal(sent[0].frame.type, 'screenshot');
  assert.equal(sent[1].kind, 'binary');
  assert.equal(sent[1].data.length, sent[0].frame.bytes);
  assert.equal(sent[0].frame.format, 'jpeg');
});

test('bez subscribe nie ma autonomicznych ramek terminala ani okien', () => {
  const sent = [];
  const session = new MacSimSession({ sendText: (text) => sent.push(JSON.parse(text)), sendBinary: () => {} });
  // Bez subskrypcji tick nie wysyła nic; requestWindows pozostaje dozwoloną odpowiedzią na komendę.
  session.receiveText(JSON.stringify({ type: 'key', chord: 'return' }));
  session.dispose();

  assert.deepEqual(sent, []);
});
