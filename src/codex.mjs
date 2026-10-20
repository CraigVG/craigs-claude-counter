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
export function findCodexBin(env = process.env) {
  if (env.CLAUDE_USAGE_CODEX_BIN) return env.CLAUDE_USAGE_CODEX_BIN;
  const home = homedir();
  const candidates = ['/opt/homebrew/bin/codex', '/usr/local/bin/codex', join(home, '.local/bin/codex'), join(home, '.npm-global/bin/codex')];
  return candidates.find((p) => existsSync(p)) || 'codex';
}

const PLAN_NAMES = { pro: 'Pro', plus: 'Plus', team: 'Team', business: 'Business', enterprise: 'Enterprise', edu: 'Edu', free: 'Free' };
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

// Cached Codex reader for the engine: at most one app-server run per `ttlMs`
// (jittered like the Claude cache), concurrent callers share one run, and a
// failure serves the last good entry marked stale. Returns [] when Codex is
// not installed or not signed in, so the board simply has no Codex section.
export function createCodexSource({ read = readCodex, ttlMs = 180_000, thresholds, random = Math.random, log = () => {} } = {}) {
  let last = null; // { entry, fetchedAt, expiresAt }
  let inflight = null;
  let unavailable = null; // reason Codex is not shown
  const get = async () => {
    const now = Date.now();
    if (last && now < last.expiresAt) return [last.entry];
    if (inflight) return inflight;
    inflight = (async () => {
      try {
        const out = await read();
        if (!out.rateLimits) throw new Error('no rate limits (not signed in?)');
        const entry = codexEntry(out, thresholds);
        const t = Date.now();
        last = { entry, fetchedAt: t, expiresAt: t + Math.round(ttlMs * (0.75 + 0.5 * random())) };
        unavailable = null;
        return [entry];
      } catch (e) {
        const reason = e.code === 'ENOENT' ? 'codex CLI not found' : String(e.message || e);
        if (reason !== unavailable) log(`[codex] unavailable: ${reason}`);
        unavailable = reason;
        if (last) {
          last.expiresAt = Date.now() + 60_000; // retry in a minute
          return [{ ...last.entry, stale: true, staleAgeMs: Date.now() - last.fetchedAt, message: `cached; ${reason}` }];
        }
        return [];
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  };
  return { get, status: () => ({ unavailable, fetchedAt: last ? new Date(last.fetchedAt).toISOString() : null }) };
}
