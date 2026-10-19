import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RANGES, parseRange, historyQuery, seriesFor, segments, nearest, timeTicks, fleetQuery, fleetGapMs } from '../src/usage-chart.mjs';

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const t0 = Date.parse('2026-10-19T12:00:00Z');
const rec = (min, session, weekly, models = []) => ({
  ts: new Date(t0 + min * MIN).toISOString(),
  session: session == null ? null : { pct: session },
  weekly: weekly == null ? null : { pct: weekly },
  models,
});

test('ranges parse with a 7d default and build the history query', () => {
  assert.equal(parseRange('30d'), '30d');
  assert.equal(parseRange('nope'), '7d');
  assert.equal(historyQuery('acct_1', '24h'), 'account=acct_1&since=24h&limit=0');
  assert.equal(historyQuery('acct_1', '90d'), 'account=acct_1&since=90d&limit=0&step=2h');
  for (const r of Object.values(RANGES)) assert.ok(r.gapMs >= 20 * MIN);
});

test('fleet queries thin long ranges and widen the gap to match', () => {
  assert.equal(fleetQuery('24h'), 'since=24h');
  assert.equal(fleetQuery('7d'), 'since=7d&step=15m');
  assert.equal(fleetQuery('90d'), 'since=90d&step=3h');
  assert.equal(fleetGapMs('24h'), 20 * MIN);
  assert.equal(fleetGapMs('7d'), 45 * MIN);
  assert.equal(fleetGapMs('90d'), 9 * HOUR);
});

test('series are weekly, session, then the first model; extra models are reported, not drawn', () => {
  const recs = [rec(0, 1, 2, [{ name: 'Fable', pct: 3 }]), rec(5, 1, 2, [{ name: 'Fable', pct: 4 }, { name: 'Opus', pct: 9 }])];
  const { series, omitted } = seriesFor(recs);
  assert.deepEqual(series.map((s) => s.key), ['weekly', 'session', 'model']);
  assert.equal(series[2].label, 'Fable weekly');
  assert.equal(series[2].value(recs[1]), 4);
  assert.deepEqual(omitted, ['Opus']);
  assert.deepEqual(seriesFor([rec(0, 1, 2)]).series.map((s) => s.key), ['weekly', 'session']);
});

test('segments break at missing values and at gaps, and clamp to 0..100', () => {
  const recs = [rec(0, 10, 50), rec(5, 20, 51), rec(10, null, null), rec(15, 30, 52), rec(20, 40, 120), rec(90, 5, 53)];
  const runs = segments(recs, (r) => r.weekly?.pct ?? null, 20 * MIN);
  assert.deepEqual(runs.map((r) => r.map(([, v]) => v)), [[50, 51], [52, 100], [53]]);
  assert.equal(runs[0][0][0], t0);
  assert.deepEqual(segments([], (r) => r, 1), []);
});

test('nearest finds the closest sample by time', () => {
  const recs = [rec(0, 1, 1), rec(5, 2, 2), rec(10, 3, 3)];
  assert.equal(nearest(recs, t0 + 3 * MIN).session.pct, 2);
  assert.equal(nearest(recs, t0 + 2 * MIN).session.pct, 1);
  assert.equal(nearest(recs, t0 + 60 * MIN).session.pct, 3);
  assert.equal(nearest([], t0), null);
});

test('time ticks land on round local times and fit the target count', () => {
  const day = timeTicks(t0 - DAY, t0);
  assert.equal(day.step, 6 * HOUR);
  assert.ok(day.ticks.length >= 3 && day.ticks.length <= 7);
  for (const t of day.ticks) {
    const d = new Date(t);
    assert.equal(d.getMinutes(), 0);
    assert.equal(d.getHours() % 6, 0);
  }
  const week = timeTicks(t0 - 7 * DAY, t0);
  assert.equal(week.step, DAY);
  for (const t of week.ticks) assert.equal(new Date(t).getHours(), 0);
  assert.ok(timeTicks(t0 - 90 * DAY, t0).ticks.length <= 7);
});
