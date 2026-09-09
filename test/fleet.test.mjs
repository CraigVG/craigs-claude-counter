import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeFleet, tierWeight, SESSION_MS, WEEK_MS } from '../src/fleet.mjs';

const NOW = Date.parse('2026-09-09T18:00:00Z');
const H = 60 * 60 * 1000;
const at = (h) => new Date(NOW + h * H).toISOString();
const win = (pct, h) => ({ pct, resetsAt: pct > 0 && h != null ? at(h) : null });
const acct = (label, tier, session, weekly, weeklyModels = []) => ({ id: label, label, tier, usage: { session, weekly, weeklyModels } });

test('tierWeight maps plans and flags unknown tiers as assumed', () => {
  // Weekly capacity: a 20x week is 2x a 5x week, not 4x (the 4x is the session bucket).
  assert.deepEqual(tierWeight('Max 20x'), { weight: 7, assumed: false });
  assert.deepEqual(tierWeight('Max 5x'), { weight: 3.5, assumed: false });
  assert.deepEqual(tierWeight('Pro'), { weight: 1, assumed: false });
  assert.deepEqual(tierWeight('max_20x_raven'), { weight: 7, assumed: false });
  assert.deepEqual(tierWeight('default_raven'), { weight: 3.5, assumed: true });
  assert.deepEqual(tierWeight(null), { weight: 3.5, assumed: true });
  assert.equal(tierWeight('Max 20x').weight / tierWeight('Max 5x').weight, 2);
});

test('empty fleet yields nulls, not NaN', () => {
  const f = computeFleet([], { now: NOW });
  assert.equal(f.usedPct, null);
  assert.equal(f.accounts.counted, 0);
  const g = computeFleet([{ id: 'x', label: 'x', error: 'needs_relogin' }], { now: NOW });
  assert.equal(g.usedPct, null);
  assert.equal(g.accounts.unknown, 1);
});

test('effective usage is the binding window, weighted by plan', () => {
  // 20x at 80% weekly (session lower) + 5x at 100% session (weekly lower)
  const f = computeFleet([
    acct('big', 'Max 20x', win(30, 2), win(80, 100)),
    acct('small', 'Max 5x', win(100, 1), win(20, 50)),
  ], { now: NOW });
  assert.equal(f.weightTotal, 10.5);
  // (7*80 + 3.5*100) / 10.5 = 86.67
  assert.equal(f.usedPct, 86.7);
  assert.equal(f.freePct, 13.3);
  assert.equal(f.accounts.blocked, 1);
  assert.equal(f.severity, 'warning');
});

test('per-model weekly can be the binding weekly window', () => {
  const f = computeFleet([acct('a', 'Pro', win(0, null), win(40, 100), [{ name: 'Fable', pct: 95, resetsAt: at(100) }])], { now: NOW });
  assert.equal(f.usedPct, 95);
  assert.equal(f.nextWeekly.kind, 'Fable weekly');
});

test('relief events split used capacity into back-soon and locked', () => {
  // One 20x account: session 90 resets in 1h, weekly 60 resets in 3d.
  const f = computeFleet([acct('a', 'Max 20x', win(90, 1), win(60, 72))], { now: NOW });
  assert.equal(f.usedPct, 90);
  assert.equal(f.backSoonPct, 30);   // session reset restores 90-60
  assert.equal(f.lockedPct, 60);     // weekly reset restores the rest
  assert.equal(f.events.length, 2);
  assert.equal(f.events[0].kind, 'session');
  assert.equal(f.events[0].restoresPct, 30);
  assert.equal(f.events[1].kind, 'weekly');
  assert.equal(f.events[1].restoresPct, 60);
  assert.equal(f.nextEvent.inMs, H);
  assert.equal(f.freshBy, at(72));
});

test('a weekly reset that lands before the session reset restores only the excess', () => {
  // weekly 80 resets in 30min, session 50 resets in 4h -> weekly event restores 30, session event 50
  const f = computeFleet([acct('a', 'Max 5x', win(50, 4), win(80, 0.5))], { now: NOW });
  assert.equal(f.events[0].kind, 'weekly');
  assert.equal(f.events[0].restoresPct, 30);
  assert.equal(f.events[1].kind, 'session');
  assert.equal(f.events[1].restoresPct, 50);
  assert.equal(f.backSoonPct, 80);   // both inside the 5h "soon" horizon
  assert.equal(f.lockedPct, 0);
});

test('events are sorted soonest first across accounts and scaled to fleet share', () => {
  const f = computeFleet([
    acct('a', 'Max 20x', win(100, 2), win(0, null)),
    acct('b', 'Max 5x', win(100, 1), win(0, null)),
  ], { now: NOW });
  assert.deepEqual(f.events.map((e) => e.account), ['b', 'a']);
  assert.equal(f.events[0].restoresPct, 33.3); // 3.5/10.5
  assert.equal(f.events[1].restoresPct, 66.7); // 7/10.5
  assert.equal(f.usedPct, 100);
  assert.equal(f.backSoonPct, 100);
});

test('past reset times count as relief now, not negative time', () => {
  const f = computeFleet([acct('a', 'Pro', win(50, -1), win(0, null))], { now: NOW });
  assert.equal(f.nextEvent.inMs, 0);
  assert.equal(f.backSoonPct, 50);
});

test('pace compares weekly usage to the elapsed share of the window', () => {
  // Window resets in 5 days -> 2 of 7 days elapsed (28.6%). 86% used -> 3x pace, exhausts before reset.
  const f = computeFleet([acct('a', 'Max 20x', win(0, null), win(86, 120))], { now: NOW });
  assert.equal(f.pace.accounts, 1);
  assert.equal(f.pace.ratio, 3.01);
  assert.equal(f.pace.exhausting.length, 1);
  assert.equal(f.pace.exhausting[0].account, 'a');
  // On-pace account: 2 days in, 28% used -> ~1.0, projected to last until reset.
  const g = computeFleet([acct('b', 'Max 20x', win(0, null), win(28, 120))], { now: NOW });
  assert.equal(g.pace.ratio, 0.98);
  assert.equal(g.pace.exhausting.length, 0);
});

test('pace ignores windows younger than two hours', () => {
  const f = computeFleet([acct('a', 'Max 20x', win(0, null), win(5, WEEK_MS / H - 1))], { now: NOW });
  assert.equal(f.pace.accounts, 0);
  assert.equal(f.pace.ratio, null);
});

test('soon horizon defaults to one session length', () => {
  const f = computeFleet([acct('a', 'Pro', win(0, null), win(50, 6))], { now: NOW });
  assert.equal(f.soonMs, SESSION_MS);
  assert.equal(f.backSoonPct, 0);
  assert.equal(f.lockedPct, 50);
});
