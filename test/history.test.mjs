import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHistory, recordFrom, parseTime, parseStep, summarize, toCsv, startUsagePoller, fleetHistory, weeklyResets } from '../src/history.mjs';

const H = 3_600_000, D = 24 * H;
const iso = (ms) => new Date(ms).toISOString();

const acct = (over = {}) => ({
  id: 'a1', label: 'ops@example.com', tier: 'Max 20x',
  usage: {
    session: { pct: 42, resetsAt: '2026-09-08T20:00:00Z', severity: 'normal' },
    weekly: { pct: 61.5, resetsAt: '2026-09-11T05:00:00Z', severity: 'normal' },
    weeklyModels: [{ name: 'Fable', pct: 22, resetsAt: '2026-09-11T05:00:00Z' }, { name: 'Ghost', pct: null }],
    overage: { enabled: true, usedUsd: 12.5, limitUsd: 100, pct: 12.5 },
  },
  ...over,
});

async function tmpHistory(opts = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'ccc-history-'));
  return { dir, history: createHistory({ dir, ...opts }), cleanup: () => rm(dir, { recursive: true, force: true }) };
}

test('recordFrom flattens an account entry and drops secrets-free extras', () => {
  const r = recordFrom(acct(), '2026-09-08T18:00:00.000Z');
  assert.deepEqual(r, {
    ts: '2026-09-08T18:00:00.000Z', account: 'a1', label: 'ops@example.com', tier: 'Max 20x',
    session: { pct: 42, resetsAt: '2026-09-08T20:00:00Z' },
    weekly: { pct: 61.5, resetsAt: '2026-09-11T05:00:00Z' },
    models: [{ name: 'Fable', pct: 22, resetsAt: '2026-09-11T05:00:00Z' }],
    overage: { usedUsd: 12.5, limitUsd: 100, pct: 12.5 },
    banked: null,
    stale: false, error: null,
  });
  const err = recordFrom({ id: 'b', label: 'b@x', error: 'needs_relogin' }, 'T');
  assert.equal(err.error, 'needs_relogin');
  assert.equal(err.session, null);
  assert.deepEqual(err.models, []);
  assert.equal(recordFrom(acct({ stale: true }), 'T').stale, true);
});

test('parseTime handles relative durations, ISO, and epoch ms', () => {
  const now = Date.parse('2026-09-08T12:00:00Z');
  assert.equal(parseTime('24h', now), now - D);
  assert.equal(parseTime('7d', now), now - 7 * D);
  assert.equal(parseTime('90m', now), now - 90 * 60_000);
  assert.equal(parseTime('2w', now), now - 14 * D);
  assert.equal(parseTime('2026-09-01T00:00:00Z', now), Date.parse('2026-09-01T00:00:00Z'));
  assert.equal(parseTime(String(now), now), now);
  assert.equal(parseTime('yesterday', now), null);
  assert.equal(parseTime('', now), null);
  assert.equal(parseStep('1h'), H);
  assert.equal(parseStep('15m'), 15 * 60_000);
  assert.equal(parseStep('nope'), null);
});

test('append writes one JSONL line per record into UTC day files', async () => {
  const { dir, history, cleanup } = await tmpHistory();
  try {
    const n = await history.append([
      recordFrom(acct(), '2026-09-08T23:59:00.000Z'),
      recordFrom(acct({ id: 'a2', label: 'two' }), '2026-09-08T23:59:00.000Z'),
      recordFrom(acct(), '2026-09-09T00:01:00.000Z'),
    ]);
    assert.equal(n, 3);
    const files = (await readdir(dir)).sort();
    assert.deepEqual(files, ['usage-2026-09-08.jsonl', 'usage-2026-09-09.jsonl']);
    const lines = (await readFile(join(dir, 'usage-2026-09-08.jsonl'), 'utf8')).trim().split('\n');
    assert.equal(lines.length, 2);
    assert.equal(JSON.parse(lines[1]).label, 'two');
    assert.equal(await history.append([]), 0);
  } finally { await cleanup(); }
});

test('query filters by window, account, downsamples by step, and caps by limit', async () => {
  const { history, cleanup } = await tmpHistory();
  try {
    const now = Date.parse('2026-09-08T12:00:00Z');
    const recs = [];
    for (let i = 0; i < 48; i++) { // every 30 min for 24h, two accounts
      const ts = iso(now - D + i * 30 * 60_000);
      recs.push(recordFrom(acct(), ts), recordFrom(acct({ id: 'a2', label: 'Team Two' }), ts));
    }
    recs.push(recordFrom(acct(), iso(now - 3 * D))); // outside the default 24h window
    await history.append(recs);

    const all = await history.query({ now });
    assert.equal(all.length, 96);
    assert.ok(Date.parse(all[0].ts) <= Date.parse(all[1].ts));

    const week = await history.query({ since: now - 7 * D, now });
    assert.equal(week.length, 97);

    const byLabel = await history.query({ account: 'team two', now });
    assert.equal(byLabel.length, 48);
    assert.ok(byLabel.every((r) => r.account === 'a2'));
    assert.equal((await history.query({ account: 'a1', now })).length, 48);

    const hourly = await history.query({ step: H, now });
    assert.equal(hourly.length, 48); // one per account per hour
    const capped = await history.query({ limit: 10, now });
    assert.equal(capped.length, 10);
    assert.equal(capped[9].ts, all[95].ts); // keeps the most recent
    const window = await history.query({ since: now - 2 * H, until: now - H, now });
    assert.equal(window.length, 6);
  } finally { await cleanup(); }
});

test('prune removes day files older than retention', async () => {
  const { dir, history, cleanup } = await tmpHistory({ retentionDays: 7 });
  try {
    const now = Date.parse('2026-09-08T12:00:00Z');
    await history.append([
      recordFrom(acct(), iso(now)),
      recordFrom(acct(), iso(now - 6 * D)),
      recordFrom(acct(), iso(now - 8 * D)),
      recordFrom(acct(), iso(now - 30 * D)),
    ]);
    const removed = await history.prune(now);
    assert.deepEqual(removed.sort(), ['usage-2026-08-09.jsonl', 'usage-2026-08-31.jsonl']);
    assert.deepEqual((await readdir(dir)).sort(), ['usage-2026-09-02.jsonl', 'usage-2026-09-08.jsonl']);
    assert.deepEqual(await createHistory({ dir, retentionDays: 0 }).prune(now), []);
  } finally { await cleanup(); }
});

test('summarize ignores sub-second jitter in reset times and counts real resets', () => {
  const t0 = Date.parse('2026-10-17T00:00:00Z');
  const mk = (i, resetsAt) => recordFrom(acct({ usage: { session: { pct: 0, resetsAt: null }, weekly: { pct: 50, resetsAt } } }), iso(t0 + i * H));
  const recs = [
    mk(0, '2026-10-17T12:59:59.832707+00:00'),
    mk(1, '2026-10-17T13:00:00.451761+00:00'),
    mk(2, '2026-10-17T12:59:59.912000+00:00'),
    mk(3, '2026-10-24T13:00:00+00:00'), // the week rolled over
    mk(4, '2026-10-24T13:00:00.120000+00:00'),
  ];
  assert.deepEqual(summarize(recs)[0].resets, { session: 0, weekly: 1 });
});

test('fleetHistory rebuilds the fleet bar at every poll and summarizes all polls', () => {
  const t0 = Date.parse('2026-10-19T00:00:00Z');
  const rec = (i, id, tier, session, weekly) => recordFrom({
    id, label: id, tier,
    usage: {
      session: { pct: session, resetsAt: iso(t0 + i * 5 * 60_000 + 2 * H) },
      weekly: { pct: weekly, resetsAt: iso(t0 + 3 * 24 * H) },
    },
  }, iso(t0 + i * 5 * 60_000));
  const recs = [
    rec(0, 'big', 'Max 20x', 0, 50), rec(0, 'small', 'Pro', 0, 0),
    rec(1, 'big', 'Max 20x', 100, 50), rec(1, 'small', 'Pro', 0, 100),
    rec(2, 'big', 'Max 20x', 0, 60), rec(2, 'small', 'Pro', 0, 20),
  ];
  const { points, summary } = fleetHistory(recs, { intervalMs: 5 * 60_000 });
  assert.equal(points.length, 3);
  // Weights 7 (20x) and 1 (Pro): poll 0 = (7*50 + 1*0) / 8 = 43.75.
  assert.equal(points[0].usedPct, 43.8);
  assert.equal(points[0].total, 2);
  assert.equal(points[0].capacity, 8);
  // Poll 1: both blocked (big by its session, small by its week).
  assert.equal(points[1].blocked, 2);
  assert.equal(points[1].usedPct, 100);
  assert.ok(points[1].backSoonPct > 0, 'the session reset within 5h is back soon');
  assert.equal(summary.polls, 3);
  assert.equal(summary.maxUsedPct, 100);
  assert.equal(summary.peakBlocked, 2);
  assert.equal(summary.blockedMs, 5 * 60_000);
  assert.equal(summary.atLimitMs, 5 * 60_000);
  // Thinning keeps the first poll per bucket; the summary still covers all.
  const thin = fleetHistory(recs, { intervalMs: 5 * 60_000, stepMs: 15 * 60_000 });
  assert.equal(thin.points.length, 1);
  assert.equal(thin.summary.polls, 3);
  assert.deepEqual(fleetHistory([]).points, []);
});

test('weeklyResets finds each weekly rollover and the unused share of the week that ended', () => {
  const t0 = Date.parse('2026-10-17T12:00:00Z');
  const mk = (min, id, tier, weekly, resetsAt) => recordFrom({ id, label: id, tier, usage: { session: { pct: 0 }, weekly: { pct: weekly, resetsAt } } }, iso(t0 + min * 60_000));
  const recs = [
    mk(0, 'a', 'Max 20x', 60, '2026-10-17T12:59:59.832Z'),
    mk(5, 'b', 'Pro', 100, '2026-10-17T12:10:00Z'),
    mk(30, 'a', 'Max 20x', 60, '2026-10-17T13:00:00.451Z'), // jitter, not a reset
    mk(35, 'b', 'Pro', 0, '2026-10-24T12:10:00Z'), // b reset fully used
    mk(65, 'a', 'Max 20x', 0, '2026-10-24T13:00:00Z'), // a reset with 40% unused
    mk(70, 'a', 'Max 20x', 5, '2026-10-24T13:00:00Z'),
  ];
  const ev = weeklyResets(recs);
  assert.deepEqual(ev.map((e) => [e.account, e.usedPct, e.unusedPct, e.units]), [['b', 100, 0, 0], ['a', 60, 40, 2.8]]);
  assert.equal(ev[1].at, '2026-10-17T13:00:00.451Z');
  assert.equal(ev[1].approx, false);
  // A banked refill: usage drops, resetsAt stays.
  assert.deepEqual(weeklyResets([mk(0, 'c', 'Pro', 90, '2026-10-20T00:00:00Z'), mk(5, 'c', 'Pro', 0, '2026-10-20T00:00:00Z')]), []);
  // fleetHistory totals them as a share of the capacity that reset.
  const fh = fleetHistory(recs);
  assert.equal(fh.summary.resets, 2);
  assert.equal(fh.summary.expiredUnusedUnits, 2.8);
  assert.equal(fh.summary.expiredUnusedPct, 35);   // 2.8 of (7 + 1) units
  assert.ok(fh.resets.every((e) => e.fleetPct != null));
});

test('summarize counts overage spent across a billing-cycle reset', () => {
  const t0 = Date.parse('2026-10-01T00:00:00Z');
  const mk = (i, used) => recordFrom(acct({ usage: { session: { pct: 0 }, weekly: { pct: 10 }, overage: { enabled: true, usedUsd: used, limitUsd: 600, pct: 0 } } }), iso(t0 + i * H));
  const o = summarize([mk(0, 500), mk(1, 580), mk(2, 0), mk(3, 25)])[0].overage;
  assert.equal(o.deltaUsd, -475);
  assert.equal(o.spentUsd, 105);
});

test('summarize reports per-account stats, resets, overage delta, and time at limit', () => {
  const t0 = Date.parse('2026-09-08T00:00:00Z');
  const mk = (i, session, weekly, resetsAt, used, extra = {}) => recordFrom(acct({
    usage: { session: { pct: session, resetsAt: 'S' }, weekly: { pct: weekly, resetsAt }, weeklyModels: [{ name: 'Fable', pct: weekly / 2 }], overage: { enabled: true, usedUsd: used, limitUsd: 100, pct: used } },
    ...extra,
  }), iso(t0 + i * H));
  const recs = [
    mk(0, 10, 50, 'W1', 1),
    mk(1, 95, 60, 'W1', 2),
    mk(2, 75, 70, 'W1', 3),
    mk(3, 20, 5, 'W2', 4.25), // weekly reset happened
    recordFrom({ id: 'a1', label: 'ops@example.com', error: 'rate_limited' }, iso(t0 + 4 * H)),
    recordFrom(acct({ id: 'b', label: 'b@x', stale: true }), iso(t0 + 4 * H)),
  ];
  const s = summarize(recs, { warnPct: 70, critPct: 90 });
  assert.equal(s.length, 2);
  const a = s.find((x) => x.account === 'a1');
  assert.equal(a.samples, 5);
  assert.equal(a.first, iso(t0));
  assert.equal(a.last, iso(t0 + 4 * H));
  assert.deepEqual(a.session, { latest: 20, first: 10, min: 10, max: 95, avg: 50 });
  assert.deepEqual(a.weekly, { latest: 5, first: 50, min: 5, max: 70, avg: 46.3 });
  assert.deepEqual(a.resets, { session: 0, weekly: 1 });
  assert.equal(a.models.Fable.max, 35);
  assert.deepEqual(a.overage, { latestUsedUsd: 4.25, firstUsedUsd: 1, deltaUsd: 3.25, spentUsd: 3.25, limitUsd: 100, latestPct: 4.25 });
  assert.equal(a.atLimitSamples, 1);
  assert.equal(a.warningSamples, 1);
  assert.equal(a.errorSamples, 1);
  assert.equal(a.latestError, 'rate_limited');
  const b = s.find((x) => x.account === 'b');
  assert.equal(b.staleSamples, 1);
  assert.equal(b.latestError, null);
});

test('toCsv flattens records with a header row', () => {
  const csv = toCsv([recordFrom(acct({ label: 'has, comma' }), '2026-09-08T18:00:00.000Z')]);
  const [head, row] = csv.trim().split('\n');
  assert.ok(head.startsWith('ts,account,label,tier,session_pct'));
  assert.ok(row.includes('"has, comma"'));
  assert.ok(row.includes('Fable:22'));
  assert.ok(row.endsWith(',12.5,100,12.5,0,'));
});

test('startUsagePoller logs one record per account on each tick', async () => {
  const { history, cleanup } = await tmpHistory();
  try {
    let calls = 0;
    const collect = async () => ({ generatedAt: iso(Date.now() + calls++), accounts: [acct(), acct({ id: 'a2', label: 'two', error: 'needs_relogin', usage: null })] });
    const poller = startUsagePoller({ collect, history, intervalMs: 60_000, initialDelayMs: 60_000 });
    try {
      assert.equal(await poller.tick(), 2);
      const recs = await history.query({ limit: 0 });
      assert.equal(recs.length, 2); // the delayed first tick has not fired
      assert.equal(recs.find((r) => r.account === 'a2').error, 'needs_relogin');
      assert.equal(recs.find((r) => r.account === 'a1').weekly.pct, 61.5);
    } finally { poller.stop(); }
  } finally { await cleanup(); }
});

test('usageFromRecord inverts recordFrom closely enough to serve as last-known usage', async () => {
  const { usageFromRecord, latestPerAccount } = await import('../src/history.mjs');
  const r = recordFrom(acct(), '2026-09-08T18:00:00.000Z');
  const u = usageFromRecord(r);
  assert.equal(u.session.pct, 42);
  assert.equal(u.session.resetsAt, '2026-09-08T20:00:00Z');
  assert.equal(u.weekly.pct, 61.5);
  assert.equal(u.weekly.severity, 'normal');
  assert.deepEqual(u.weeklyModels.map((m) => m.name), ['Fable']);
  assert.equal(u.overage.enabled, true);
  assert.equal(u.overage.usedUsd, 12.5);
  assert.equal(usageFromRecord(recordFrom({ id: 'x', label: 'x', error: 'needs_relogin' })), null);
  // latestPerAccount keeps the newest record with numbers per account id.
  const older = recordFrom(acct({ usage: { ...acct().usage, weekly: { pct: 10 } } }), '2026-09-08T17:00:00.000Z');
  const errored = { ts: '2026-09-08T19:00:00.000Z', account: 'a1', label: 'x', session: null, weekly: null, error: 'fetch_failed' };
  const m = latestPerAccount([older, r, errored]);
  assert.equal(m.get('a1').weekly.pct, 61.5);
});

test('banked reset counts survive the record round trip', async () => {
  const { usageFromRecord } = await import('../src/history.mjs');
  const banked = { left: 1, total: 1, nextExpiresAt: '2026-10-22T16:00:00+00:00', usableNow: true, grants: [{ id: 'g', label: 'Launch reset', left: 1 }] };
  const r = recordFrom(acct({ usage: { ...acct().usage, bankedResets: banked } }), '2026-09-30T18:00:00.000Z');
  assert.deepEqual(r.banked, { left: 1, total: 1, nextExpiresAt: '2026-10-22T16:00:00+00:00' });
  assert.equal(usageFromRecord(r).bankedResets.left, 1);
  assert.equal(recordFrom(acct(), '2026-09-30T18:00:00.000Z').banked, null);
});
