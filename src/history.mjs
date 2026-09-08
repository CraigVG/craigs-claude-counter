// Usage history: an append-only JSONL log of every account's limits over time,
// written by the server's background poller so the record keeps growing even
// when nobody has the dashboard open. Agents read it back through
// GET /api/history (raw records) and GET /api/history/summary (per-account
// stats), or straight from the files.
//
// Layout: <dir>/usage-YYYY-MM-DD.jsonl (UTC day), one line per account per
// poll. Files older than `retentionDays` are pruned. No tokens or secrets are
// ever written here — only labels, tiers and percentages.
import { appendFile, mkdir, readdir, readFile, unlink } from 'node:fs/promises';
import { join } from 'node:path';

const FILE_RE = /^usage-(\d{4}-\d{2}-\d{2})\.jsonl$/;
const DAY_MS = 86_400_000;

const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
const fileFor = (ms) => `usage-${dayOf(ms)}.jsonl`;
const num = (v) => (v == null || Number.isNaN(Number(v)) ? null : Number(v));

// Flatten one /api/usage account entry into a compact, stable log record.
export function recordFrom(a, ts = new Date().toISOString()) {
  const u = a.usage || null;
  const win = (w) => (w && w.pct != null ? { pct: num(w.pct), resetsAt: w.resetsAt || null } : null);
  return {
    ts,
    account: a.id,
    label: a.label || a.id,
    tier: a.tier || null,
    session: u ? win(u.session) : null,
    weekly: u ? win(u.weekly) : null,
    models: u ? (u.weeklyModels || []).filter((m) => m && m.pct != null).map((m) => ({ name: m.name, pct: num(m.pct), resetsAt: m.resetsAt || null })) : [],
    overage: u && u.overage && u.overage.enabled
      ? { usedUsd: num(u.overage.usedUsd), limitUsd: num(u.overage.limitUsd), pct: num(u.overage.pct) }
      : null,
    stale: !!a.stale,
    error: a.error || null,
  };
}

// "24h" / "7d" / "90m" / "30s" -> ms before `now`; ISO date/time -> its epoch ms;
// a plain number -> epoch ms. Returns null when unparseable.
export function parseTime(v, now = Date.now()) {
  if (v == null || v === '') return null;
  const s = String(v).trim();
  const rel = s.match(/^(\d+(?:\.\d+)?)\s*([smhdw])$/i);
  if (rel) {
    const mult = { s: 1000, m: 60_000, h: 3_600_000, d: DAY_MS, w: 7 * DAY_MS }[rel[2].toLowerCase()];
    return now - Number(rel[1]) * mult;
  }
  if (/^\d{10,}$/.test(s)) return Number(s);
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

// "1h" / "15m" / "1d" -> bucket width in ms (for downsampling). null when unset.
export function parseStep(v) {
  if (v == null || v === '') return null;
  const m = String(v).trim().match(/^(\d+(?:\.\d+)?)\s*([smhdw])$/i);
  if (!m) return null;
  const mult = { s: 1000, m: 60_000, h: 3_600_000, d: DAY_MS, w: 7 * DAY_MS }[m[2].toLowerCase()];
  return Number(m[1]) * mult;
}

function matchesAccount(r, account) {
  if (!account) return true;
  const q = String(account).toLowerCase();
  return r.account === account || String(r.label || '').toLowerCase() === q || String(r.label || '').toLowerCase().includes(q);
}

// Per-account statistics over a set of records (already filtered/sorted by
// time). `resets` counts how often a window's resetsAt changed between
// consecutive samples, so a weekly delta can be read in context.
export function summarize(records, { warnPct = 70, critPct = 90 } = {}) {
  const byAcct = new Map();
  for (const r of records) {
    if (!byAcct.has(r.account)) byAcct.set(r.account, []);
    byAcct.get(r.account).push(r);
  }
  const stats = (vals) => {
    const xs = vals.filter((v) => v != null);
    if (!xs.length) return null;
    const sum = xs.reduce((a, b) => a + b, 0);
    return { latest: xs[xs.length - 1], first: xs[0], min: Math.min(...xs), max: Math.max(...xs), avg: Math.round((sum / xs.length) * 10) / 10 };
  };
  const resets = (rs, key) => {
    let n = 0, prev;
    for (const r of rs) {
      const at = r[key]?.resetsAt || null;
      if (prev !== undefined && at && prev && at !== prev) n++;
      if (at) prev = at;
    }
    return n;
  };
  const out = [];
  for (const [account, rs] of byAcct) {
    const last = rs[rs.length - 1];
    const live = rs.filter((r) => r.session || r.weekly);
    const worst = (r) => Math.max(r.session?.pct ?? 0, r.weekly?.pct ?? 0);
    const models = {};
    for (const r of rs) for (const m of r.models || []) {
      (models[m.name] ||= []).push(m.pct);
    }
    const overages = rs.map((r) => r.overage).filter(Boolean);
    out.push({
      account,
      label: last.label,
      tier: last.tier,
      samples: rs.length,
      first: rs[0].ts,
      last: last.ts,
      session: stats(rs.map((r) => r.session?.pct ?? null)),
      weekly: stats(rs.map((r) => r.weekly?.pct ?? null)),
      resets: { session: resets(rs, 'session'), weekly: resets(rs, 'weekly') },
      models: Object.fromEntries(Object.entries(models).map(([k, v]) => [k, stats(v)])),
      overage: overages.length
        ? { latestUsedUsd: overages[overages.length - 1].usedUsd, firstUsedUsd: overages[0].usedUsd, deltaUsd: Math.round((overages[overages.length - 1].usedUsd - overages[0].usedUsd) * 100) / 100, limitUsd: overages[overages.length - 1].limitUsd, latestPct: overages[overages.length - 1].pct }
        : null,
      atLimitSamples: live.filter((r) => worst(r) >= critPct).length,
      warningSamples: live.filter((r) => worst(r) >= warnPct && worst(r) < critPct).length,
      staleSamples: rs.filter((r) => r.stale).length,
      errorSamples: rs.filter((r) => r.error).length,
      latestError: last.error || null,
    });
  }
  return out;
}

export function toCsv(records) {
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const head = ['ts', 'account', 'label', 'tier', 'session_pct', 'session_resets_at', 'weekly_pct', 'weekly_resets_at', 'models', 'overage_used_usd', 'overage_limit_usd', 'overage_pct', 'stale', 'error'];
  const rows = records.map((r) => [
    r.ts, r.account, r.label, r.tier,
    r.session?.pct, r.session?.resetsAt, r.weekly?.pct, r.weekly?.resetsAt,
    (r.models || []).map((m) => `${m.name}:${m.pct}`).join(';'),
    r.overage?.usedUsd, r.overage?.limitUsd, r.overage?.pct,
    r.stale ? 1 : 0, r.error,
  ].map(esc).join(','));
  return [head.join(','), ...rows].join('\n') + '\n';
}

export function createHistory({ dir, retentionDays = 90, log = () => {} }) {
  if (!dir) throw new Error('history dir required');
  let ready = null;
  const ensureDir = () => (ready ||= mkdir(dir, { recursive: true }));

  async function listFiles() {
    await ensureDir();
    const names = await readdir(dir);
    return names.filter((n) => FILE_RE.test(n)).sort();
  }

  // Append records for one poll. All records share a day file by their ts.
  async function append(records) {
    if (!records || !records.length) return 0;
    await ensureDir();
    const byFile = new Map();
    for (const r of records) {
      const f = fileFor(Date.parse(r.ts) || Date.now());
      byFile.set(f, (byFile.get(f) || '') + JSON.stringify(r) + '\n');
    }
    for (const [f, data] of byFile) await appendFile(join(dir, f), data, 'utf8');
    return records.length;
  }

  // Records in [since, until], oldest first. `account` matches id or label
  // (substring, case-insensitive). `step` keeps the first sample per account
  // per bucket. `limit` keeps the most recent N after filtering.
  async function query({ account, since, until, step, limit = 5000, now = Date.now() } = {}) {
    const from = since == null ? now - DAY_MS : since;
    const to = until == null ? now : until;
    const files = (await listFiles()).filter((n) => {
      const day = Date.parse(n.match(FILE_RE)[1] + 'T00:00:00Z');
      return day + DAY_MS > from && day <= to;
    });
    const out = [];
    const lastBucket = new Map();
    for (const f of files) {
      let text;
      try { text = await readFile(join(dir, f), 'utf8'); } catch { continue; }
      for (const line of text.split('\n')) {
        if (!line) continue;
        let r;
        try { r = JSON.parse(line); } catch { continue; }
        const t = Date.parse(r.ts);
        if (Number.isNaN(t) || t < from || t > to) continue;
        if (!matchesAccount(r, account)) continue;
        if (step) {
          const b = Math.floor(t / step);
          if (lastBucket.get(r.account) === b) continue;
          lastBucket.set(r.account, b);
        }
        out.push(r);
      }
    }
    out.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts));
    return limit && out.length > limit ? out.slice(out.length - limit) : out;
  }

  // Delete day files older than retentionDays. Returns the names removed.
  async function prune(now = Date.now()) {
    if (!retentionDays || retentionDays <= 0) return [];
    const cutoff = dayOf(now - retentionDays * DAY_MS);
    const removed = [];
    for (const n of await listFiles()) {
      const day = n.match(FILE_RE)[1];
      if (day < cutoff) {
        try { await unlink(join(dir, n)); removed.push(n); } catch { /* already gone */ }
      }
    }
    if (removed.length) log(`pruned ${removed.length} history file(s) older than ${retentionDays}d`);
    return removed;
  }

  return { dir, retentionDays, append, query, prune, listFiles };
}

// Poll usage on an interval and append one record per account. `collect`
// returns the same payload as GET /api/usage. Returns { stop, tick } so callers
// (and tests) can drive a tick directly.
export function startUsagePoller({ collect, history, intervalMs = 300_000, log = () => {} }) {
  let lastPrune = 0;
  const tick = async () => {
    const snap = await collect();
    const ts = snap.generatedAt || new Date().toISOString();
    const n = await history.append((snap.accounts || []).map((a) => recordFrom(a, ts)));
    if (Date.now() - lastPrune > DAY_MS) { lastPrune = Date.now(); await history.prune().catch(() => {}); }
    return n;
  };
  const safeTick = () => tick().then((n) => log(`logged ${n} account(s)`)).catch((e) => log(`tick failed: ${e.message || e}`));
  const timer = setInterval(safeTick, intervalMs);
  if (timer.unref) timer.unref();
  safeTick();
  return { stop: () => clearInterval(timer), tick };
}
