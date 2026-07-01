import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeUsage, severityFor, prettyTier, fetchUsage, fetchProfile } from '../src/usage.mjs';

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
