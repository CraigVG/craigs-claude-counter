import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
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

test('headroom remains available: most available on top, at-limit last', () => {
  assert.deepEqual(labels(sortAccounts(board, { key: 'headroom', dir: 'asc' })), ['charlie', 'bravo', 'delta', 'alpha']);
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

test('ties fall back to weekly reset, then name, and the input is not mutated', () => {
  const tied = [acct('zed', 'Max 20x', 50, 30), acct('amy', 'Max 20x', 10, 30), acct('bob', 'Max 20x', 10, 30)];
  const before = labels(tied);
  assert.deepEqual(labels(sortAccounts(tied, { key: 'weekly', dir: 'asc' })), ['amy', 'bob', 'zed']);
  assert.deepEqual(labels(tied), before);
});

test('clicking a header cycles natural direction, reverse, then back to weekly reset', () => {
  let s = DEFAULT_SORT;
  s = nextSort(s, 'weekly'); assert.deepEqual(s, { key: 'weekly', dir: 'asc' });
  s = nextSort(s, 'weekly'); assert.deepEqual(s, { key: 'weekly', dir: 'desc' });
  s = nextSort(s, 'weekly'); assert.deepEqual(s, DEFAULT_SORT);
  assert.deepEqual(nextSort(DEFAULT_SORT, 'plan'), { key: 'plan', dir: 'desc' });
  assert.deepEqual(nextSort({ key: 'weekly', dir: 'desc' }, 'overage'), { key: 'overage', dir: 'desc' });
});

test('stored sort strings round-trip and junk falls back to weekly reset', () => {
  assert.deepEqual(parseSort('overage:asc'), { key: 'overage', dir: 'asc' });
  assert.deepEqual(parseSort('headroom:asc'), { key: 'headroom', dir: 'asc' });
  assert.deepEqual(parseSort('nope:asc'), DEFAULT_SORT);
  assert.deepEqual(parseSort(null), DEFAULT_SORT);
});


test('default is earliest weekly reset, even at zero; unknowns and ties keep input order', () => {
  const dated = (name, pct, resetsAt) => ({ id: name, label: name, usage: { weekly: { pct, resetsAt } } });
  const rows = [dated('unknown-z', 90, null), dated('later', 0, '2026-10-20T10:00:00Z'),
    dated('tie-z', 90, '2026-10-15T10:00:00Z'), dated('unknown-a', 0, 'invalid'),
    dated('tie-a', 0, '2026-10-15T05:00:00-05:00'), dated('first', 100, '2026-10-14T10:00:00Z')];
  assert.deepEqual(DEFAULT_SORT, { key: 'reset', dir: 'asc' });
  assert.deepEqual(labels(sortAccounts(rows)), ['first', 'tie-z', 'tie-a', 'later', 'unknown-z', 'unknown-a']);
  assert.deepEqual(labels(sortAccounts(rows, { key: 'reset', dir: 'desc' })), ['later', 'tie-z', 'tie-a', 'first', 'unknown-z', 'unknown-a']);
  assert.deepEqual(labels(rows), ['unknown-z', 'later', 'tie-z', 'unknown-a', 'tie-a', 'first']);
  assert.deepEqual(parseSort('reset:desc'), { key: 'reset', dir: 'desc' });
});


test('web weekly cells show the reset date at zero and missing usage; sessions stay idle', () => {
  const page = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
  const functions = page.slice(page.indexOf('function weeklyResetText('), page.indexOf('function modelCell('));
  const cell = runInNewContext(functions + '\nmetricCell', {
    esc: (s) => String(s), sevOf: () => 'idle', sevCls: () => 'is-idle', resetText: () => 'countdown',
  });
  const w = { pct: 0, resetsAt: '2026-10-15T10:00:00Z' };
  const date = new Date(w.resetsAt).toLocaleString(undefined, { month:'short', day:'numeric', hour:'numeric', minute:'2-digit' });
  assert.ok(cell(w, 'weekly').includes(date));
  assert.ok(cell({ ...w, pct: null }, 'weekly').includes(date));
  assert.ok(cell(w, 'session').includes('idle'));
  assert.ok(cell({ pct: 0, resetsAt: null }, 'weekly').includes('reset unknown'));
});
