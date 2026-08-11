import test from 'node:test';
import assert from 'node:assert/strict';
import { rankingRows, generateCode, hashToken, historyRows, summaryRows, historyTotals } from '../src/store.js';

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

test('historia zachowuje sesje, w których nikt nic nie powiedział', () => {
  // „Zaczęliśmy i nic z tego nie wyszło" to prawdziwy fakt o pracy; ukrycie
  // takiej sesji wyglądałoby jak zgubione dane.
  const rows = historyRows([
    { id: '7', name: 'coding session', started_at: 'a', ended_at: 'b',
      words: '0', seconds: '0', dictations: '0', speakers: '0' },
  ]);

  assert.equal(rows.length, 1);
  assert.equal(rows[0].words, 0);
  assert.equal(rows[0].averageWords, 0, 'zero dyktowań nie dzieli przez zero');
});

test('liczby z historii są liczbami, nie tekstem z pg', () => {
  const rows = historyRows([
    { id: '7', name: null, started_at: 'a', ended_at: null,
      words: '120', seconds: '90.5', dictations: '3', speakers: '2' },
  ]);

  assert.strictEqual(rows[0].words, 120);
  assert.strictEqual(rows[0].id, 7);
  assert.strictEqual(rows[0].speakers, 2);
  assert.equal(rows[0].averageWords, 40);
});

test('trwająca sesja ma pusty koniec, a nie zmyśloną datę', () => {
  const rows = historyRows([
    { id: '8', name: null, started_at: 'a', ended_at: null,
      words: '10', seconds: '5', dictations: '1', speakers: '1' },
  ]);

  assert.equal(rows[0].endedAt, null);
});

test('podsumowanie pokoju liczy sesje na osobę i sortuje po słowach', () => {
  const people = summaryRows([
    { device_id: 'b', name: 'Wojtek', sessions: '2', words: '300', seconds: '100', dictations: '5' },
    { device_id: 'a', name: 'Filip', sessions: '4', words: '900', seconds: '400', dictations: '12' },
  ]);

  assert.deepEqual(people.map((p) => p.name), ['Filip', 'Wojtek']);
  assert.strictEqual(people[0].sessions, 4);
  assert.equal(people[0].averageWords, 75);
});

test('sumy pokoju biorą się z osób, nie z sesji', () => {
  // Sesje sumowałyby to samo drugi raz, gdyby ktoś kiedyś dodał do nich
  // wiersze zbiorcze; osoby są tu jedynym źródłem liczb.
  const sessions = historyRows([
    { id: '1', name: null, started_at: 'a', ended_at: 'b',
      words: '900', seconds: '400', dictations: '12', speakers: '1' },
  ]);
  const people = summaryRows([
    { device_id: 'a', name: 'Filip', sessions: '1', words: '900', seconds: '400', dictations: '12' },
  ]);

  assert.deepEqual(historyTotals(1, people), {
    sessions: 1, people: 1, words: 900, seconds: 400, dictations: 12,
  });
});

test('pusty pokój ma zera, a nie NaN', () => {
  assert.deepEqual(historyTotals(0, []), {
    sessions: 0, people: 0, words: 0, seconds: 0, dictations: 0,
  });
});

test('sumy nie mylą strony wyników z całym pokojem', () => {
  // Lista to jedna strona; gdyby licznik brał jej długość, pokój ze stoma
  // sesjami raportowałby dwadzieścia.
  const people = summaryRows([
    { device_id: 'a', name: 'Filip', sessions: '100', words: '5', seconds: '1', dictations: '1' },
  ]);

  assert.equal(historyTotals(100, people).sessions, 100);
});
