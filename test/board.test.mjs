import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sortAccounts, nextSort, parseSort, headroomKey, DEFAULT_SORT } from '../src/board.mjs';

const win = (pct) => ({ pct, resetsAt: null });
const acct = (label, tier, session, weekly, extra = {}) => ({
  id: label, label, tier,
  usage: { session: win(session), weekly: win(weekly), weeklyModels: extra.models || [], overage: extra.overage || null },
});
const relogin = (label) => ({ id: label, label, tier: 'Pro', error: 'needs_relogin' });
const labels = (list) => list.map((a) => a.label);

const board = [
  acct('bravo', 'Max 20x', 10, 80, { models: [{ name: 'Fable', pct: 99 }] }),
  acct('alpha', 'Team 5x', 95, 40, { overage: { enabled: true, usedUsd: 12.5 } }),
  relogin('delta'),
  acct('charlie', 'Pro', 0, 20, { models: [{ name: 'Fable', pct: 5 }], overage: { enabled: true, usedUsd: 300 } }),
];

test('default sort is headroom: most available on top, at-limit last', () => {
  assert.deepEqual(labels(sortAccounts(board)), ['charlie', 'bravo', 'delta', 'alpha']);
  assert.deepEqual(labels(sortAccounts(board, DEFAULT_SORT)), labels(sortAccounts(board)));
  assert.ok(headroomKey(board[1]) > headroomKey(board[2])); // at limit sits below needs-relogin
});

test('usage columns sort by their own window; accounts without data sink', () => {
  assert.deepEqual(labels(sortAccounts(board, { key: 'weekly', dir: 'asc' })), ['charlie', 'alpha', 'bravo', 'delta']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'weekly', dir: 'desc' })), ['bravo', 'alpha', 'charlie', 'delta']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'session', dir: 'desc' })), ['alpha', 'bravo', 'charlie', 'delta']);
  // Only bravo and charlie report a per-model limit; the rest sink in either direction.
  assert.deepEqual(labels(sortAccounts(board, { key: 'model', dir: 'desc' })).slice(0, 2), ['bravo', 'charlie']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'model', dir: 'asc' })).slice(0, 2), ['charlie', 'bravo']);
});

test('plan sorts by weekly capacity, overage by dollars spent, account by name', () => {
  assert.deepEqual(labels(sortAccounts(board, { key: 'plan', dir: 'desc' })), ['bravo', 'alpha', 'charlie', 'delta']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'overage', dir: 'desc' })).slice(0, 2), ['charlie', 'alpha']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'account', dir: 'asc' })), ['alpha', 'bravo', 'charlie', 'delta']);
  assert.deepEqual(labels(sortAccounts(board, { key: 'account', dir: 'desc' })), ['delta', 'charlie', 'bravo', 'alpha']);
});

test('ties fall back to headroom, then name, and the input is not mutated', () => {
  const tied = [acct('zed', 'Max 20x', 50, 30), acct('amy', 'Max 20x', 10, 30), acct('bob', 'Max 20x', 10, 30)];
  const before = labels(tied);
  assert.deepEqual(labels(sortAccounts(tied, { key: 'weekly', dir: 'asc' })), ['amy', 'bob', 'zed']);
  assert.deepEqual(labels(tied), before);
});

test('clicking a header cycles natural direction, reverse, then back to headroom', () => {
  let s = DEFAULT_SORT;
  s = nextSort(s, 'weekly'); assert.deepEqual(s, { key: 'weekly', dir: 'asc' });
  s = nextSort(s, 'weekly'); assert.deepEqual(s, { key: 'weekly', dir: 'desc' });
  s = nextSort(s, 'weekly'); assert.deepEqual(s, DEFAULT_SORT);
  assert.deepEqual(nextSort(DEFAULT_SORT, 'plan'), { key: 'plan', dir: 'desc' });
  assert.deepEqual(nextSort({ key: 'weekly', dir: 'desc' }, 'overage'), { key: 'overage', dir: 'desc' });
});

test('stored sort strings round-trip and junk falls back to headroom', () => {
  assert.deepEqual(parseSort('overage:asc'), { key: 'overage', dir: 'asc' });
  assert.deepEqual(parseSort('headroom:asc'), DEFAULT_SORT);
  assert.deepEqual(parseSort('nope:asc'), DEFAULT_SORT);
  assert.deepEqual(parseSort(null), DEFAULT_SORT);
});
