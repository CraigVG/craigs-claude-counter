// Fetch and normalize the Claude Code subscription usage endpoint.
import { USAGE_URL, PROFILE_URL, ANTHROPIC_BETA, USER_AGENT } from './config.mjs';

// Map an Anthropic rate_limit_tier to a short, friendly plan name.
export function prettyTier(rateLimitTier, orgType) {
  const t = String(rateLimitTier || '');
  if (/max_20x/.test(t)) return 'Max 20x';
  if (/max_5x/.test(t)) return 'Max 5x';
  if (/max/.test(t)) return 'Max';
  if (/pro/.test(t)) return 'Pro';
  if (orgType === 'claude_max') return 'Max';
  if (orgType === 'claude_pro') return 'Pro';
  return rateLimitTier || null;
}

// Map a raw API utilization percent to a severity bucket using thresholds.
export function severityFor(pct, warnPct = 70, critPct = 90) {
  if (pct == null) return 'unknown';
  if (pct >= critPct) return 'critical';
  if (pct >= warnPct) return 'warning';
  return 'normal';
}

function round(n) {
  return n == null ? null : Math.round(n * 10) / 10;
}

// Pull a window {pct, resetsAt, severity, active} out of the raw payload.
// Prefers the structured `limits[]` array; falls back to the legacy fields.
function windowFrom(raw, { limitKind, legacyKey, modelName }, thresholds) {
  const limits = Array.isArray(raw?.limits) ? raw.limits : [];
  let entry = null;
  if (modelName) {
    entry = limits.find(
      (l) => l.group === 'weekly' && l.scope?.model?.display_name === modelName,
    );
  } else if (limitKind) {
    entry = limits.find((l) => l.kind === limitKind);
  }
  if (entry) {
    return {
      pct: round(entry.percent),
      resetsAt: entry.resets_at ?? null,
      severity: entry.severity ?? severityFor(entry.percent, thresholds.warnPct, thresholds.critPct),
      active: entry.is_active ?? null,
    };
  }
  const legacy = raw?.[legacyKey];
  if (legacy && legacy.utilization != null) {
    return {
      pct: round(legacy.utilization),
      resetsAt: legacy.resets_at ?? null,
      severity: severityFor(legacy.utilization, thresholds.warnPct, thresholds.critPct),
      active: null,
    };
  }
  return null;
}

// Collect every per-model weekly sub-limit the API reports, in payload order.
// The set of models is not fixed — it has been Opus/Sonnet, and is now Fable —
// so we surface whatever `weekly` limits carry a model scope rather than
// hardcoding names. Falls back to the legacy seven_day_* fields when the
// structured limits[] array is absent.
function weeklyModelsFrom(raw, thresholds) {
  const limits = Array.isArray(raw?.limits) ? raw.limits : [];
  const models = [];
  for (const l of limits) {
    const name = l?.scope?.model?.display_name;
    if (l.group === 'weekly' && name) {
      models.push({
        name,
        pct: round(l.percent),
        resetsAt: l.resets_at ?? null,
        severity: l.severity ?? severityFor(l.percent, thresholds.warnPct, thresholds.critPct),
        active: l.is_active ?? null,
      });
    }
  }
  if (models.length === 0) {
    for (const [name, legacyKey] of [['Opus', 'seven_day_opus'], ['Sonnet', 'seven_day_sonnet']]) {
      const w = windowFrom(raw, { modelName: name, legacyKey }, thresholds);
      if (w) models.push({ name, ...w });
    }
  }
  return models;
}

// Turn the raw /api/oauth/usage JSON into a stable, UI-friendly shape.
export function normalizeUsage(raw, thresholds = { warnPct: 70, critPct: 90 }) {
  const session = windowFrom(
    raw,
    { limitKind: 'session', legacyKey: 'five_hour' },
    thresholds,
  );
  const weekly = windowFrom(
    raw,
    { limitKind: 'weekly_all', legacyKey: 'seven_day' },
    thresholds,
  );
  const weeklyModels = weeklyModelsFrom(raw, thresholds);
  // Backward-compat convenience fields for the released v1.0.0 macOS binary,
  // which decodes weeklyOpus / weeklySonnet by name. New clients read weeklyModels.
  const byName = (n) => weeklyModels.find((m) => m.name === n) || null;
  const weeklyOpus = byName('Opus');
  const weeklySonnet = byName('Sonnet');

  let overage = null;
  const spend = raw?.spend;
  const extra = raw?.extra_usage;
  if (spend && spend.enabled) {
    const exp = spend.used?.exponent ?? 2;
    const div = 10 ** exp;
    overage = {
      usedUsd: (spend.used?.amount_minor ?? 0) / div,
      limitUsd: (spend.limit?.amount_minor ?? 0) / div,
      pct: round(spend.percent),
      currency: spend.used?.currency ?? 'USD',
      enabled: true,
    };
  } else if (extra && extra.is_enabled) {
    const div = 10 ** (extra.decimal_places ?? 2);
    overage = {
      usedUsd: (extra.used_credits ?? 0) / div,
      limitUsd: (extra.monthly_limit ?? 0) / div,
      pct: round(extra.utilization),
      currency: extra.currency ?? 'USD',
      enabled: true,
    };
  }

  return { session, weekly, weeklyModels, weeklyOpus, weeklySonnet, overage };
}

// Fetch live usage for one access token. `fetchImpl` is injectable for tests.
export async function fetchUsage(accessToken, { fetchImpl = fetch, thresholds } = {}) {
  const res = await fetchImpl(USAGE_URL, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'anthropic-beta': ANTHROPIC_BETA,
      'User-Agent': USER_AGENT,
    },
  });
  if (!res.ok) {
    const err = new Error(`usage endpoint returned ${res.status}`);
    err.status = res.status;
    throw err;
  }
  const raw = await res.json();
  return normalizeUsage(raw, thresholds);
}

// Fetch the account profile (email + plan) used to label an account.
export async function fetchProfile(accessToken, { fetchImpl = fetch } = {}) {
  const res = await fetchImpl(PROFILE_URL, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'anthropic-beta': ANTHROPIC_BETA,
      'User-Agent': USER_AGENT,
    },
  });
  if (!res.ok) {
    const err = new Error(`profile endpoint returned ${res.status}`);
    err.status = res.status;
    throw err;
  }
  const raw = await res.json();
  const acct = raw?.account || {};
  const org = raw?.organization || {};
  return {
    email: acct.email || null,
    displayName: acct.display_name || acct.full_name || null,
    tier: prettyTier(org.rate_limit_tier, org.organization_type),
    rateLimitTier: org.rate_limit_tier || null,
    extraUsageEnabled: !!org.has_extra_usage_enabled,
  };
}
