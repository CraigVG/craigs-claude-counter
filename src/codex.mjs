// Codex (ChatGPT plan) usage, read through the Codex CLI's own app server:
// `codex app-server` speaks JSON-RPC over stdio, and `account/read` +
// `account/rateLimits/read` return the signed-in account and its rate-limit
// windows. The ChatGPT login stays inside Codex (its CODEX_HOME); this engine
// never sees a token.
//
// Codex is shaped like a Claude account entry ({ id, label, tier, usage })
// so the fleet math, history log and charts treat it the same way. It is
// served separately (`codex` in /api/usage, not in `accounts`) because other
// tools read `accounts` as the list of Claude seats.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { severityFor } from './usage.mjs';

// The LaunchAgent runs with a minimal PATH, so look where Codex is installed.
export function findCodexBin(env = process.env, exists = existsSync) {
  if (env.CLAUDE_USAGE_CODEX_BIN) return env.CLAUDE_USAGE_CODEX_BIN;
  const home = homedir();
  // The ChatGPT desktop app bundles the CLI; on a Mac with no standalone
  // install that copy is the only one (2026-11: the standalone one went away
  // on one Mac and the counter showed a week-old number).
  const bundled = 'ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
  const candidates = ['/opt/homebrew/bin/codex', '/usr/local/bin/codex', join(home, '.local/bin/codex'), join(home, '.npm-global/bin/codex'),
    join('/Applications', bundled), join(home, 'Applications', bundled)];
  return candidates.find((p) => exists(p)) || 'codex';
}

const PLAN_NAMES = { pro: 'Pro', promax: 'Pro Max', plus: 'Plus', team: 'Team', business: 'Business', enterprise: 'Enterprise', edu: 'Edu', free: 'Free' };
export const codexTier = (planType) => `Codex ${PLAN_NAMES[String(planType || '').toLowerCase()] || planType || 'plan'}`;

// One Codex rate-limit window -> the { pct, resetsAt, severity, active } shape
// the Claude windows use. resetsAt arrives as epoch seconds.
function win(w, thresholds) {
  if (!w || w.usedPercent == null) return null;
  const pct = Math.max(0, Math.min(100, Number(w.usedPercent)));
  const at = w.resetsAt != null ? new Date(Number(w.resetsAt) * 1000).toISOString() : null;
  return { pct, resetsAt: at, severity: severityFor(pct, thresholds?.warnPct, thresholds?.critPct), active: pct > 0, windowMins: w.windowDurationMins ?? null };
}

// The app server's account + rateLimits results -> an account entry. Codex
// reports a primary and an optional secondary window; a window of a day or
// more is the weekly one, a shorter one is the session (5 h) window.
export function codexEntry({ account, rateLimits }, thresholds) {
  const r = rateLimits || {};
  const wins = [r.primary, r.secondary].filter(Boolean);
  const weeklyW = wins.find((w) => (w.windowDurationMins ?? 0) >= 24 * 60) || null;
  const sessionW = wins.find((w) => w !== weeklyW && (w.windowDurationMins ?? Infinity) < 24 * 60) || null;
  const credits = r.credits || null;
  const balance = credits && credits.balance != null ? Number(credits.balance) : null;
  const email = account?.email || null;
  return {
    id: `codex:${r.accountId || email || 'default'}`,
    provider: 'codex',
    label: email ? `Codex · ${email}` : 'Codex',
    email,
    tier: codexTier(account?.planType || r.planType),
    usage: {
      session: win(sessionW, thresholds),
      weekly: win(weeklyW, thresholds),
      weeklyModels: [],
      overage: null,
      credits: credits ? { balance, unlimited: !!credits.unlimited, hasCredits: !!credits.hasCredits } : null,
      limitReached: r.rateLimitReachedType || (r.ordinaryUsageAllowed === false ? 'limit' : null),
    },
  };
}

// Ask a fresh `codex app-server` for the account and its limits, then stop it.
// Resolves { account, rateLimits } or rejects (not installed, not signed in,
// timeout). `spawnImpl` is injectable for tests.
export function readCodex({ bin = findCodexBin(), codexHome = process.env.CODEX_HOME, timeoutMs = 15_000, spawnImpl = spawn } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, PATH: [dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', process.env.PATH || ''].join(':') };
    if (codexHome) env.CODEX_HOME = codexHome;
    let child;
    try { child = spawnImpl(bin, ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], env }); } catch (e) { reject(e); return; }
    const pending = new Map();
    let buf = '';
    let done = false;
    const finish = (err, val) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { child.kill(); } catch { /* already gone */ }
      if (err) reject(err); else resolve(val);
    };
    const timer = setTimeout(() => finish(new Error('codex app-server timed out')), timeoutMs);
    child.on('error', (e) => finish(e.code === 'ENOENT' ? Object.assign(new Error('codex CLI not found'), { code: 'ENOENT' }) : e));
    child.on('exit', (code) => finish(new Error(`codex app-server exited (${code})`)));
    if (child.stdin) child.stdin.on('error', () => { /* child gone; exit handler reports it */ });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        const cb = msg && msg.id != null && pending.get(msg.id);
        if (cb) { pending.delete(msg.id); cb(msg); }
      }
    });
    let nextId = 1;
    const call = (method, params = {}) => new Promise((res, rej) => {
      const id = nextId++;
      pending.set(id, (msg) => (msg.error ? rej(Object.assign(new Error(msg.error.message || 'codex error'), { rpc: msg.error })) : res(msg.result)));
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
    (async () => {
      await call('initialize', { clientInfo: { name: 'craigs-claude-counter', title: "Craig's Claude Counter", version: '1' } });
      const [acct, limits] = await Promise.all([call('account/read'), call('account/rateLimits/read')]);
      finish(null, { account: acct?.account || null, rateLimits: limits?.rateLimits || null });
    })().catch((e) => finish(e));
  });
}

export const ageText = (ms) => (ms < 3_600_000 ? `${Math.max(1, Math.round(ms / 60_000))}m` : ms < 86_400_000 ? `${Math.round(ms / 3_600_000)}h` : `${Math.round(ms / 86_400_000)}d`);

// Cached reader for a provider that is read through its own CLI (Codex here,
// Gemini in src/gemini.mjs): at most one CLI run per `ttlMs` (jittered like
// the Claude cache), concurrent callers share one run, and a failure serves
// the last good entry marked stale. Returns [] when the CLI is not installed
// or not signed in, so the board simply has no section for it. After a
// failure the next run waits a minute (or the error's `retryMs`), with or
// without a last good entry.
export function createCliSource({ read, entryFrom, tag, ttlMs = 180_000, random = Math.random, log = () => {} }) {
  let last = null; // { entry, fetchedAt, expiresAt }
  let inflight = null;
  let unavailable = null; // reason the provider is not shown
  let failed = false; // the latest read failed: `last` is old data
  let retryAt = 0;
  // The last good entry, marked as old. Between retries too: a failed read
  // must never be served as if it were current.
  const staleEntry = () => ({ ...last.entry, stale: true, staleAgeMs: Date.now() - last.fetchedAt, message: `cached ${ageText(Date.now() - last.fetchedAt)} ago; ${unavailable}` });
  const get = async () => {
    const now = Date.now();
    if (failed && now < retryAt) return last ? [staleEntry()] : [];
    if (last && !failed && now < last.expiresAt) return [last.entry];
    if (inflight) return inflight;
    inflight = (async () => {
      try {
        const entry = entryFrom(await read());
        const t = Date.now();
        last = { entry, fetchedAt: t, expiresAt: t + Math.round(ttlMs * (0.75 + 0.5 * random())) };
        unavailable = null;
        failed = false;
        return [entry];
      } catch (e) {
        const reason = e.code === 'ENOENT' ? `${tag} CLI not found` : String(e.message || e);
        if (reason !== unavailable) log(`[${tag}] unavailable: ${reason}`);
        unavailable = reason;
        failed = true;
        retryAt = Date.now() + (e.retryMs ?? 60_000);
        return last ? [staleEntry()] : [];
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  };
  return { get, status: () => ({ unavailable, fetchedAt: last ? new Date(last.fetchedAt).toISOString() : null }) };
}

export function createCodexSource({ read = readCodex, ttlMs = 180_000, thresholds, random = Math.random, log = () => {} } = {}) {
  const entryFrom = (out) => {
    if (!out.rateLimits) throw new Error('no rate limits (not signed in?)');
    return codexEntry(out, thresholds);
  };
  return createCliSource({ read, entryFrom, tag: 'codex', ttlMs, random, log });
}
