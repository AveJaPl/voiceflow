import test from 'node:test';
import assert from 'node:assert/strict';
import { rankingRows, generateCode, hashToken } from '../src/store.js';

test('ranking sumuje słowa i sekundy per urządzenie i sortuje malejąco', () => {
  const rows = [
    { device_id: 'w', name: 'Wojtek', words: 40, seconds: 30, dictations: 2 },
    { device_id: 'f', name: 'Filip', words: 120, seconds: 90, dictations: 5 },
  ];

  const result = rankingRows(rows);

  assert.deepEqual(result.map((r) => r.name), ['Filip', 'Wojtek']);
  assert.equal(result[0].averageWords, 24, '120 słów / 5 dyktowań');
});

test('ranking bez dyktowań nie dzieli przez zero', () => {
  const result = rankingRows([
    { device_id: 'f', name: 'Filip', words: 0, seconds: 0, dictations: 0 },
  ]);

  assert.equal(result[0].averageWords, 0);
});

test('liczby z Postgresa przychodzą jako tekst i muszą zostać liczbami', () => {
  // pg zwraca BIGINT i SUM jako string — bez konwersji ranking sortowałby
  // leksykograficznie i "90" wypadłoby przed "120".
  const result = rankingRows([
    { device_id: 'f', name: 'Filip', words: '120', seconds: '90.5', dictations: '5' },
    { device_id: 'w', name: 'Wojtek', words: '90', seconds: '30', dictations: '3' },
  ]);

  assert.equal(result[0].name, 'Filip');
  assert.strictEqual(result[0].words, 120);
  assert.strictEqual(result[0].seconds, 90.5);
});

test('kod pokoju ma 6 znaków i pomija znaki mylące', () => {
  const code = generateCode();

  assert.equal(code.length, 6);
  assert.match(code, /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/, 'bez 0/O i 1/I/L');
});

test('kody pokoi się nie powtarzają w rozsądnej próbie', () => {
  const codes = new Set(Array.from({ length: 200 }, () => generateCode()));

  assert.equal(codes.size, 200);
});

test('token nigdy nie jest przechowywany w postaci jawnej', () => {
  const hash = hashToken('sekretny-token');

  assert.notEqual(hash, 'sekretny-token');
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.equal(hash, hashToken('sekretny-token'), 'ten sam token daje ten sam hash');
});
