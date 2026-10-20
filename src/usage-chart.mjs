// Account usage-over-time chart: the pure parts (ranges, series extraction,
// gap splitting, time ticks). Shared with the browser (served as
// /usage-chart.mjs) so the page and the tests use identical code. The macOS
// app mirrors the ranges in macos/App/HistorySheet.swift.
//
// Input is the `records` array from GET /api/history (see src/history.mjs).
// No I/O.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

// Time ranges offered in the account view. `step` downsamples long ranges
// (first sample per bucket) so a 90-day chart stays a few hundred points.
// `gapMs`: two samples further apart than this are not joined by a line, so
// an engine that was off or an account that errored shows as a gap.
export const RANGES = {
  '24h': { label: '24h', ms: DAY, step: null, gapMs: 20 * MIN },
  '7d': { label: '7d', ms: 7 * DAY, step: null, gapMs: 20 * MIN },
  '30d': { label: '30d', ms: 30 * DAY, step: '30m', gapMs: 2 * HOUR },
  '90d': { label: '90d', ms: 90 * DAY, step: '2h', gapMs: 8 * HOUR },
};
export const DEFAULT_RANGE = '7d';

// The fleet chart thins harder (the fleet number moves slowly and each point
// costs a fleet computation upstream): one point per this step.
export const FLEET_STEPS = { '24h': null, '7d': '15m', '30d': '1h', '90d': '3h' };

// Query string for GET /api/history/fleet, and the gap beyond which fleet
// points are not joined (a missing poll is 5 min; a missing step bucket is
// a real outage).
export function fleetQuery(range) {
  const key = parseRange(range);
  const p = new URLSearchParams({ since: key });
  if (FLEET_STEPS[key]) p.set('step', FLEET_STEPS[key]);
  return p.toString();
}
export function fleetGapMs(range) {
  const key = parseRange(range);
  const step = { '15m': 15 * MIN, '1h': HOUR, '3h': 3 * HOUR }[FLEET_STEPS[key]] || 0;
  return Math.max(RANGES[key].gapMs, 3 * step);
}

export function parseRange(s) {
  return RANGES[s] ? s : DEFAULT_RANGE;
}

// The query string for GET /api/history for one account and range.
export function historyQuery(accountId, range) {
  const r = RANGES[parseRange(range)];
  const p = new URLSearchParams({ account: accountId, since: parseRange(range), limit: '0' });
  if (r.step) p.set('step', r.step);
  return p.toString();
}

// The series an account's chart draws, in fixed color order: weekly (all
// models), session, then the first per-model weekly limit seen in the range.
// A second model is not drawn (it would need a fourth color); its name is
// returned in `omitted` so the page can say so.
export function seriesFor(records) {
  const models = [];
  for (const r of records || []) for (const m of r.models || []) {
    if (m && m.name && !models.includes(m.name)) models.push(m.name);
  }
  // Codex may report no 5-hour window; leave the session series out then.
  const hasSession = (records || []).some((r) => r.session?.pct != null);
  const out = [
    { key: 'weekly', label: 'Weekly', value: (r) => r.weekly?.pct ?? null },
    ...(hasSession ? [{ key: 'session', label: 'Session (5h)', value: (r) => r.session?.pct ?? null }] : []),
  ];
  if (models.length) {
    const name = models[0];
    out.push({ key: 'model', label: `${name} weekly`, dashed: true, value: (r) => (r.models || []).find((m) => m.name === name)?.pct ?? null });
  }
  return { series: out, omitted: models.slice(1) };
}

// Split one series into runs of [t, value] points. A run breaks at a sample
// with no value or where two samples are more than `gapMs` apart.
export function segments(records, value, gapMs) {
  const runs = [];
  let run = null, lastT = null;
  for (const r of records || []) {
    const t = Date.parse(r.ts);
    if (Number.isNaN(t)) continue;
    const v = value(r);
    if (v == null || Number.isNaN(Number(v))) { run = null; lastT = t; continue; }
    if (!run || (lastT != null && t - lastT > gapMs)) { run = []; runs.push(run); }
    run.push([t, Math.max(0, Math.min(100, Number(v)))]);
    lastT = t;
  }
  return runs;
}

// The record nearest to time `t` (records sorted by ts). null when empty.
export function nearest(records, t) {
  if (!records || !records.length) return null;
  let lo = 0, hi = records.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (Date.parse(records[mid].ts) < t) lo = mid; else hi = mid;
  }
  const dl = Math.abs(Date.parse(records[lo].ts) - t), dh = Math.abs(Date.parse(records[hi].ts) - t);
  return dh < dl ? records[hi] : records[lo];
}

const TICK_STEPS = [HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR, DAY, 2 * DAY, 7 * DAY, 14 * DAY];

// X-axis ticks for [from, to]: about `target` ticks on round local times
// (whole hours, or local midnights once the step is a day or more).
// Returns { step, ticks: [ms...] }.
export function timeTicks(from, to, target = 7) {
  const span = Math.max(1, to - from);
  const step = TICK_STEPS.find((s) => span / s <= target) ?? TICK_STEPS[TICK_STEPS.length - 1];
  const start = new Date(from);
  if (step >= DAY) start.setHours(0, 0, 0, 0);
  else {
    // Whole hours on a multiple of the step (3 PM, 6 PM, ...).
    const h = step / HOUR;
    start.setMinutes(0, 0, 0);
    start.setHours(Math.floor(start.getHours() / h) * h);
  }
  const ticks = [];
  for (let d = start; d.getTime() <= to; ) {
    if (d.getTime() >= from) ticks.push(d.getTime());
    if (step >= DAY) d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + step / DAY);
    else d = new Date(d.getTime() + step);
  }
  // Day ticks on a 7- or 14-day step start on the first midnight, which can
  // be any weekday; that is fine for reading.
  return { step, ticks };
}
