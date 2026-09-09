// Fleet aggregation: one number, one bar, and one schedule for "how
// constrained are we across every account, and when does capacity come back?"
//
// The model
// ---------
// Percentages from different plans are not comparable, so every account is
// weighted by its plan's *weekly* capacity: the bar is denominated in "how much
// work can the fleet do this week". The plan multipliers (5x / 20x) describe the
// 5-hour session bucket; the weekly buckets are much closer together — a Max
// 20x week is only about 2x a Max 5x week (observed), and a Max 5x week about
// 3.5x a Pro week (Anthropic's published hour ranges). Session limits therefore
// do not change an account's share of the bar; they act as throttles that take
// the account out of rotation until its session resets.
//
// Within one account the windows are not additive either: the account is
// blocked by whichever window is highest, so its *effective* usage is
// max(session, weekly, per-model weekly). Fleet usage is the weighted mean of
// effective usage; fleet free capacity is the weighted mean of headroom.
//
// Time is folded in through resets. Both windows drop straight to zero at
// their reset time (session: 5h after first use; weekly: 7d after first use),
// so each account yields at most two "relief" events. Playing them in order
// tells exactly how much of the fleet's used capacity comes back at each one:
// after the earlier reset the account is still bound by the later window's
// percentage, so the earlier event restores (effective - later), the later
// event restores the rest. Used capacity is then split into "back within 5h"
// (any reset inside the next session-length) and "locked until a weekly reset".
//
// Pace compares each weekly window's usage to the fraction of the window
// elapsed: 87% used with 29% of the week gone is 3x sustainable pace, and at
// that rate the account runs out before it resets.
//
// Pure function; takes the /api/usage `accounts` array. No I/O.

export const SESSION_MS = 5 * 60 * 60 * 1000;
export const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
// Weekly capacity relative to Pro. Max 20x = 2 x Max 5x (observed), Max 5x =
// 3.5 x Pro (published 140-280 vs 40-80 Sonnet-hours a week). Unknown plans
// are weighted as Max 5x and flagged. These are the weights the bar uses.
export const DEFAULT_WEIGHTS = { 'Max 20x': 7, 'Max 5x': 3.5, Max: 3.5, Pro: 1, unknown: 3.5 };
// The 5-hour session bucket does follow the plan multiplier. Not used for the
// bar (see the model note above); exported for anyone reasoning about burst rate.
export const SESSION_WEIGHTS = { 'Max 20x': 20, 'Max 5x': 5, Max: 5, Pro: 1, unknown: 5 };
// A weekly window this young has too little signal for a pace projection.
const MIN_PACE_ELAPSED_MS = 2 * 60 * 60 * 1000;

const pct1 = (n) => Math.round(n * 10) / 10;
const ms = (iso) => { const t = iso ? new Date(iso).getTime() : NaN; return Number.isNaN(t) ? null : t; };

export function tierWeight(tier, weights = DEFAULT_WEIGHTS) {
  if (tier && weights[tier] != null) return { weight: weights[tier], assumed: false };
  const t = String(tier || '').toLowerCase();
  if (/20x/.test(t)) return { weight: weights['Max 20x'] ?? 7, assumed: false };
  if (/5x/.test(t)) return { weight: weights['Max 5x'] ?? 3.5, assumed: false };
  if (/max/.test(t)) return { weight: weights.Max ?? 3.5, assumed: false };
  if (/pro/.test(t)) return { weight: weights.Pro ?? 1, assumed: false };
  return { weight: weights.unknown ?? 3.5, assumed: true };
}

export function severityFor(pct, warnPct = 70, critPct = 90) {
  if (pct == null) return 'unknown';
  if (pct >= critPct) return 'critical';
  if (pct >= warnPct) return 'warning';
  return 'normal';
}

// Per-account breakdown: effective usage, the two relief events, and pace.
function analyzeAccount(a, { now, weights }) {
  const u = a.usage;
  const { weight, assumed } = tierWeight(a.tier, weights);
  const session = u.session && u.session.pct != null ? u.session : null;
  const sPct = session ? Math.max(0, session.pct) : 0;
  const sAt = session && sPct > 0 ? ms(session.resetsAt) : null;

  // The binding weekly-scale window: overall weekly or any per-model weekly.
  let wPct = u.weekly && u.weekly.pct != null ? Math.max(0, u.weekly.pct) : 0;
  let wAt = wPct > 0 ? ms(u.weekly?.resetsAt) : null;
  let wKind = 'weekly';
  for (const m of u.weeklyModels || []) {
    if (m && m.pct != null && m.pct > wPct) { wPct = m.pct; wAt = ms(m.resetsAt); wKind = `${m.name} weekly`; }
  }

  const effective = Math.max(sPct, wPct);
  const label = a.label || a.id;
  const events = [];
  // Only windows with a known reset time can be relieved; the rest stays "locked".
  const s = sPct > 0 && sAt != null ? { at: sAt, pct: sPct, kind: 'session' } : null;
  const w = wPct > 0 && wAt != null ? { at: wAt, pct: wPct, kind: wKind } : null;
  if (s && w) {
    const [first, second] = s.at <= w.at ? [s, w] : [w, s];
    events.push({ at: first.at, kind: first.kind, restores: effective - second.pct });
    events.push({ at: second.at, kind: second.kind, restores: second.pct });
  } else if (s || w) {
    const only = s || w;
    // The other window has no reset scheduled (or is at 0), so this one restores everything it holds.
    events.push({ at: only.at, kind: only.kind, restores: only.pct });
  }
  const evs = events.filter((e) => e.restores > 0).map((e) => ({ ...e, account: label, weight, restoresW: e.restores * weight }));

  // Pace over the overall weekly window (the per-model window shares its reset).
  let pace = null;
  const weeklyPct = u.weekly && u.weekly.pct != null ? Math.max(0, u.weekly.pct) : null;
  const weeklyAt = ms(u.weekly?.resetsAt);
  if (weeklyPct != null && weeklyAt != null && weeklyAt > now) {
    const elapsedMs = Math.min(WEEK_MS, Math.max(0, now - (weeklyAt - WEEK_MS)));
    const elapsed = elapsedMs / WEEK_MS;
    let exhaustsAt = null;
    if (weeklyPct >= 100) exhaustsAt = now;
    else if (elapsedMs >= MIN_PACE_ELAPSED_MS && weeklyPct > 0) exhaustsAt = now + ((100 - weeklyPct) / weeklyPct) * elapsedMs;
    pace = {
      elapsed,
      usable: elapsedMs >= MIN_PACE_ELAPSED_MS,
      ratio: elapsedMs >= MIN_PACE_ELAPSED_MS && elapsed > 0 ? weeklyPct / (elapsed * 100) : null,
      exhaustsAt,
      exhaustsBeforeReset: exhaustsAt != null && exhaustsAt < weeklyAt,
      resetsAt: weeklyAt,
    };
  }

  return { id: a.id, label, tier: a.tier || null, weight, assumed, effective, sessionPct: sPct, weeklyPct: wPct, weeklyKind: wKind, weeklyResetsAt: wAt, events: evs, pace };
}

export function computeFleet(accounts, { now = Date.now(), weights = DEFAULT_WEIGHTS, warnPct = 70, critPct = 90, soonMs = SESSION_MS } = {}) {
  const list = Array.isArray(accounts) ? accounts : [];
  const known = list.filter((a) => a.usage && (a.usage.session || a.usage.weekly));
  const unknown = list.length - known.length;
  const empty = {
    accounts: { total: list.length, counted: 0, unknown, blocked: 0, weightsAssumed: 0 },
    weightTotal: 0, usedPct: null, freePct: null, backSoonPct: null, lockedPct: null, severity: 'unknown',
    soonMs, events: [], nextEvent: null, nextWeekly: null, freshBy: null,
    pace: { ratio: null, accounts: 0, exhausting: [] }, perAccount: [], now: new Date(now).toISOString(),
  };
  if (!known.length) return empty;

  const per = known.map((a) => analyzeAccount(a, { now, weights }));
  const W = per.reduce((s, p) => s + p.weight, 0);
  const usedW = per.reduce((s, p) => s + p.weight * Math.min(100, p.effective), 0);
  const blocked = per.filter((p) => p.effective >= 100).length;

  // Relief schedule, soonest first. Events already in the past mean the
  // upstream hasn't re-polled yet; treat them as arriving now.
  const events = per.flatMap((p) => p.events)
    .map((e) => ({ at: new Date(Math.max(e.at, now)).toISOString(), inMs: Math.max(0, e.at - now), kind: e.kind, account: e.account, tier: null, restoresPct: pct1((100 * e.restoresW) / (W * 100)) , _w: e.restoresW }))
    .sort((x, y) => x.inMs - y.inMs);
  const backSoonW = events.filter((e) => e.inMs <= soonMs).reduce((s, e) => s + e._w, 0);
  for (const e of events) delete e._w;

  const usedPct = pct1((100 * usedW) / (W * 100));
  const backSoonPct = pct1((100 * Math.min(backSoonW, usedW)) / (W * 100));
  const lockedPct = pct1(Math.max(0, usedPct - backSoonPct));
  const freePct = pct1(Math.max(0, 100 - usedPct));

  const weeklyEvents = events.filter((e) => e.kind !== 'session');
  const freshBy = weeklyEvents.length ? weeklyEvents.reduce((m, e) => (e.at > m ? e.at : m), weeklyEvents[0].at) : null;

  const paced = per.filter((p) => p.pace && p.pace.usable);
  const paceUsedW = paced.reduce((s, p) => s + p.weight * (p.weeklyPct || 0), 0);
  const paceBudgetW = paced.reduce((s, p) => s + p.weight * 100 * p.pace.elapsed, 0);
  const exhausting = per.filter((p) => p.pace && p.pace.exhaustsBeforeReset).map((p) => ({ account: p.label, weeklyPct: p.weeklyPct, exhaustsAt: new Date(p.pace.exhaustsAt).toISOString(), resetsAt: new Date(p.pace.resetsAt).toISOString() }));

  return {
    accounts: { total: list.length, counted: per.length, unknown, blocked, weightsAssumed: per.filter((p) => p.assumed).length },
    weightTotal: W,
    usedPct, freePct, backSoonPct, lockedPct,
    severity: severityFor(usedPct, warnPct, critPct),
    soonMs,
    events,
    nextEvent: events[0] || null,
    nextWeekly: weeklyEvents[0] || null,
    freshBy,
    pace: {
      ratio: paceBudgetW > 0 ? Math.round((paceUsedW / paceBudgetW) * 100) / 100 : null,
      accounts: paced.length,
      exhausting,
    },
    perAccount: per.map((p) => ({ id: p.id, label: p.label, tier: p.tier, weight: p.weight, weightAssumed: p.assumed, effectivePct: pct1(p.effective), sharePct: pct1((100 * p.weight) / W), paceRatio: p.pace && p.pace.ratio != null ? Math.round(p.pace.ratio * 100) / 100 : null })),
    now: new Date(now).toISOString(),
  };
}
