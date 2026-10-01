import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeUsage, bankedResetsFrom, severityFor, prettyTier, fetchUsage, fetchProfile } from '../src/usage.mjs';
import { USAGE_RESETS_URL } from '../src/config.mjs';

// Real captured response from GET /api/oauth/usage (2026-06-18).
const SAMPLE = {
  five_hour: { utilization: 59.0, resets_at: '2026-06-18T21:20:00.940227+00:00' },
  seven_day: { utilization: 69.0, resets_at: '2026-06-19T05:00:00.940244+00:00' },
  seven_day_opus: null,
  seven_day_sonnet: { utilization: 14.0, resets_at: '2026-06-19T05:00:00.940251+00:00' },
  extra_usage: { is_enabled: true, monthly_limit: 200000, used_credits: 37431.0, utilization: 18.7155, currency: 'USD', decimal_places: 2 },
  limits: [
    { kind: 'session', group: 'session', percent: 59, severity: 'normal', resets_at: '2026-06-18T21:20:00.940227+00:00', scope: null, is_active: false },
    { kind: 'weekly_all', group: 'weekly', percent: 69, severity: 'normal', resets_at: '2026-06-19T05:00:00.940244+00:00', scope: null, is_active: true },
    { kind: 'weekly_scoped', group: 'weekly', percent: 14, severity: 'normal', resets_at: '2026-06-19T05:00:00.940251+00:00', scope: { model: { id: null, display_name: 'Sonnet' }, surface: null }, is_active: false },
  ],
  spend: { used: { amount_minor: 37431, currency: 'USD', exponent: 2 }, limit: { amount_minor: 200000, currency: 'USD', exponent: 2 }, percent: 19, severity: 'normal', enabled: true },
};

test('normalizeUsage parses session and weekly from limits[]', () => {
  const u = normalizeUsage(SAMPLE);
  assert.equal(u.session.pct, 59);
  assert.equal(u.session.severity, 'normal');
  assert.equal(u.session.resetsAt, '2026-06-18T21:20:00.940227+00:00');
  assert.equal(u.weekly.pct, 69);
  assert.equal(u.weekly.active, true);
});

test('normalizeUsage extracts per-model weekly sub-limits', () => {
  const u = normalizeUsage(SAMPLE);
  assert.equal(u.weeklyOpus, null);
  assert.equal(u.weeklySonnet.pct, 14);
  // Dynamic array mirrors the scoped models the API reports, in order.
  assert.deepEqual(u.weeklyModels.map((m) => m.name), ['Sonnet']);
  assert.equal(u.weeklyModels[0].pct, 14);
});

test('normalizeUsage surfaces new scoped models (Fable) dynamically', () => {
  const raw = {
    five_hour: { utilization: 5, resets_at: 'x' },
    seven_day: { utilization: 25, resets_at: 'y' },
    seven_day_opus: null,
    seven_day_sonnet: null,
    limits: [
      { kind: 'session', group: 'session', percent: 5, severity: 'normal', resets_at: 'x', scope: null, is_active: false },
      { kind: 'weekly_all', group: 'weekly', percent: 25, severity: 'normal', resets_at: 'y', scope: null, is_active: true },
      { kind: 'weekly_scoped', group: 'weekly', percent: 3, severity: 'normal', resets_at: 'z', scope: { model: { id: null, display_name: 'Fable' }, surface: null }, is_active: false },
    ],
  };
  const u = normalizeUsage(raw);
  assert.equal(u.weeklyModels.length, 1);
  assert.equal(u.weeklyModels[0].name, 'Fable');
  assert.equal(u.weeklyModels[0].pct, 3);
  assert.equal(u.weeklyModels[0].active, false);
  // Legacy convenience fields stay null when neither Opus nor Sonnet is scoped.
  assert.equal(u.weeklyOpus, null);
  assert.equal(u.weeklySonnet, null);
});

test('normalizeUsage prefers spend (dollars) for overage', () => {
  const u = normalizeUsage(SAMPLE);
  assert.equal(u.overage.enabled, true);
  assert.equal(u.overage.usedUsd, 374.31);
  assert.equal(u.overage.limitUsd, 2000);
  assert.equal(u.overage.pct, 19);
});

test('normalizeUsage falls back to legacy fields when limits[] absent', () => {
  const legacy = { five_hour: SAMPLE.five_hour, seven_day: SAMPLE.seven_day, seven_day_sonnet: SAMPLE.seven_day_sonnet };
  const u = normalizeUsage(legacy);
  assert.equal(u.session.pct, 59);
  assert.equal(u.weekly.pct, 69);
  assert.equal(u.weeklySonnet.pct, 14);
});

test('normalizeUsage falls back to extra_usage when spend disabled', () => {
  const noSpend = { ...SAMPLE, spend: { ...SAMPLE.spend, enabled: false } };
  const u = normalizeUsage(noSpend);
  assert.equal(u.overage.usedUsd, 374.31);
  assert.equal(u.overage.limitUsd, 2000);
});

test('severity thresholds bucket correctly', () => {
  assert.equal(severityFor(10), 'normal');
  assert.equal(severityFor(75), 'warning');
  assert.equal(severityFor(95), 'critical');
  assert.equal(severityFor(null), 'unknown');
  assert.equal(severityFor(85, 80, 95), 'warning');
});

test('computed severity used when API omits it', () => {
  const noSev = { limits: [{ kind: 'session', group: 'session', percent: 92, resets_at: 'x' }] };
  const u = normalizeUsage(noSev);
  assert.equal(u.session.severity, 'critical');
});

test('prettyTier maps rate_limit_tier', () => {
  assert.equal(prettyTier('default_claude_max_20x'), 'Max 20x');
  assert.equal(prettyTier('default_claude_max_5x'), 'Max 5x');
  assert.equal(prettyTier('default_claude_pro'), 'Pro');
  assert.equal(prettyTier(null, 'claude_max'), 'Max');
  assert.equal(prettyTier('default_claude_max_5x', 'claude_team'), 'Team 5x');
  assert.equal(prettyTier(null, 'claude_team'), 'Team');
});

test('fetchUsage throws with status on non-OK', async () => {
  const fetchImpl = async () => ({ ok: false, status: 401 });
  await assert.rejects(() => fetchUsage('tok', { fetchImpl }), (e) => e.status === 401);
});

test('fetchProfile returns email + friendly tier', async () => {
  const fetchImpl = async () => ({
    ok: true,
    json: async () => ({
      account: { email: 'a@b.com', display_name: 'A', full_name: 'A B' },
      organization: { rate_limit_tier: 'default_claude_max_20x', organization_type: 'claude_max', has_extra_usage_enabled: true },
    }),
  });
  const p = await fetchProfile('tok', { fetchImpl });
  assert.equal(p.email, 'a@b.com');
  assert.equal(p.tier, 'Max 20x');
  assert.equal(p.extraUsageEnabled, true);
});

// Real captured `cedar_ember` block from GET /api/oauth/usage?cedar_ember=1
// with a Claude Code User-Agent (2026-09-30): one launch reset, already spent.
const CEDAR_EMBER = {
  eligible: true, ineligible_reason: null, at_limit: false, exhausted: [],
  grants: [{
    id: 'opus55-launch-promax-20260921',
    label: 'Claude Opus 5.5 launch: one usage-limit reset for Pro and Max',
    resets_total: 1, resets_left: 0,
    starts_at: '2026-09-22T16:00:00+00:00', ends_at: '2026-10-22T16:00:00+00:00',
    clears: ['five_hour', 'seven_day', 'seven_day_overage_included'],
    paused: false, usable_now: false, use_requires_limit: false,
    percent_used: { five_hour: 76, seven_day: 46, seven_day_overage_included: 0 },
    blocking: [], arm: null,
  }],
  next_grant_id: null, weekly_resets_at: '2026-10-05T21:00:00+00:00', cooldown_until: null,
  event_props: { surface: 'claude_code_cli', tier: 'claude_max_20x', tenure_bucket: '90-364', billing_path: 'stripe', billing_period: 'unknown', extra_usage_state: 'enabled' },
};
const SEP30 = Date.parse('2026-09-30T12:00:00Z');

test('bankedResetsFrom reads a spent grant as zero left', () => {
  const r = bankedResetsFrom({ cedar_ember: CEDAR_EMBER }, SEP30);
  assert.equal(r.eligible, true);
  assert.equal(r.left, 0);
  assert.equal(r.total, 1);
  assert.equal(r.usableNow, false);
  assert.equal(r.nextExpiresAt, null);
  assert.equal(r.grants.length, 1);
  assert.equal(r.grants[0].useRequiresLimit, false);
  assert.deepEqual(r.grants[0].clears, ['five_hour', 'seven_day', 'seven_day_overage_included']);
});

test('bankedResetsFrom sums live grants and reports the soonest expiry', () => {
  const g = CEDAR_EMBER.grants[0];
  const raw = { cedar_ember: { ...CEDAR_EMBER, grants: [
    { ...g, id: 'a', resets_left: 1, usable_now: true },
    { ...g, id: 'b', resets_total: 2, resets_left: 2, ends_at: '2026-10-10T00:00:00+00:00', paused: true },
    { ...g, id: 'old', resets_left: 1, ends_at: '2026-09-01T00:00:00+00:00' },
    { id: 'bad' },
  ] } };
  const r = bankedResetsFrom(raw, SEP30);
  assert.equal(r.left, 3);
  assert.equal(r.total, 3);
  assert.equal(r.usableNow, true);
  assert.equal(r.nextExpiresAt, '2026-10-10T00:00:00+00:00');
  assert.deepEqual(r.grants.map((x) => x.id), ['a', 'b']);
});

test('bankedResetsFrom is null when the block is absent; ineligible reads as empty', () => {
  assert.equal(bankedResetsFrom({}), null);
  assert.equal(bankedResetsFrom({ cedar_ember: null }), null);
  assert.equal(normalizeUsage(SAMPLE).bankedResets, null);
  const r = bankedResetsFrom({ cedar_ember: { eligible: false, ineligible_reason: 'surface', grants: [] } });
  assert.equal(r.eligible, false);
  assert.equal(r.ineligibleReason, 'surface');
  assert.equal(r.left, 0);
});

test('fetchUsage asks for banked resets as the Claude Code CLI', async () => {
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, ua: init.headers['User-Agent'] }; return { ok: true, json: async () => ({ ...SAMPLE, cedar_ember: CEDAR_EMBER }) }; };
  const u = await fetchUsage('tok', { fetchImpl });
  assert.equal(seen.url, USAGE_RESETS_URL);
  assert.match(seen.url, /[?&]cedar_ember=1\b/);
  assert.match(seen.ua, /^claude-cli\//);
  assert.equal(u.bankedResets.total, 1);
});
