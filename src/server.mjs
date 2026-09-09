// Tiny HTTP server: serves the dashboard page and a small JSON API.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadConfig, REFRESH_SKEW_MS } from './config.mjs';
import { createCredStore, newAccountId } from './credstore.mjs';
import * as oauthLib from './oauth.mjs';
import * as usageLib from './usage.mjs';
import { createHistory, startUsagePoller, parseTime, parseStep, summarize, toCsv } from './history.mjs';
import { computeFleet } from './fleet.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WEB_DIR = join(__dirname, '..', 'web');

// Single-flight token refresh per account. Concurrent callers share one refresh
// promise so a rotating refresh token is never spent twice — Anthropic rotates
// refresh tokens and revokes the whole chain if one is reused (reuse detection),
// which is what silently killed all accounts before this guard existed.
export async function refreshAccount(account, { oauth, credstore, locks }) {
  if (locks && locks.has(account.id)) return locks.get(account.id);
  const p = (async () => {
    let tokens;
    try {
      tokens = await oauth.refresh({ refreshToken: account.refreshToken });
    } catch (e) {
      // 400/401 means the refresh token itself is dead -> the user must re-login.
      if (e.status === 400 || e.status === 401) e.needsRelogin = true;
      throw e;
    }
    const updated = {
      ...account,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken || account.refreshToken,
      expiresAt: tokens.expiresAt,
    };
    await credstore.putAccount(updated);
    return updated;
  })();
  if (locks) {
    locks.set(account.id, p);
    p.catch(() => {}).finally(() => { if (locks.get(account.id) === p) locks.delete(account.id); });
  }
  return p;
}

// Refresh an account's token if it is missing or close to expiry. Persists the
// new token via credstore.putAccount. Returns the (possibly updated) account.
export async function ensureFresh(account, { oauth, credstore, now = Date.now(), skewMs = REFRESH_SKEW_MS, locks } = {}) {
  const fresh = account.expiresAt && account.expiresAt - now > skewMs;
  if (fresh) return account;
  if (!account.refreshToken) {
    const err = new Error('no refresh token');
    err.needsRelogin = true;
    throw err;
  }
  return refreshAccount(account, { oauth, credstore, locks });
}

// Proactively keep tokens alive so accounts stay logged in even when the
// dashboard is never opened. Refreshes any token within `refreshWithinMs` of
// expiry, on a timer, through the single-flight lock. Returns a stop function.
export function startBackgroundRefresh({ credstore, oauth, locks, intervalMs = 30 * 60_000, refreshWithinMs = 60 * 60_000, log = () => {} }) {
  const tick = async () => {
    let accounts = [];
    try { accounts = await credstore.listAccounts(); } catch { return; }
    const now = Date.now();
    for (const a of accounts) {
      if (!a.refreshToken) continue;
      if (a.expiresAt && a.expiresAt - now > refreshWithinMs) continue; // still fresh enough
      try { await refreshAccount(a, { oauth, credstore, locks }); log(`kept ${a.label} logged in`); }
      catch (e) { log(`refresh failed for ${a.label}: ${e.needsRelogin ? 'needs re-login' : (e.message || e)}`); }
    }
  };
  const timer = setInterval(() => { tick().catch(() => {}); }, intervalMs);
  if (timer.unref) timer.unref();
  tick().catch(() => {}); // run once at startup
  return () => clearInterval(timer);
}

// Build the aggregate payload for one account, isolating all failures.
// Uses an in-memory cache so the upstream endpoint is hit at most once per
// account per cacheTtl, and serves the last-known value (stale) on errors.
async function accountUsage(account, deps) {
  const { oauth, credstore, usage, thresholds, cache, locks, cacheTtl = 60_000, cooldownMs = 120_000, now = Date.now() } = deps;
  const base = { id: account.id, label: account.label, tier: account.tier || null };
  const cached = cache && cache.get(account.id);
  // Permanent auth failure: surface it (with dimmed last-known data) instead of
  // silently serving stale cache forever.
  const needsRelogin = () => ({ ...base, error: 'needs_relogin', message: 'sign in again', usage: (cached && cached.usage) || null, stale: !!(cached && cached.usage) });

  const serveStale = (extra) => cached && cached.usage
    ? { ...base, usage: cached.usage, stale: true, staleAgeMs: Date.now() - cached.fetchedAt, ...extra }
    : null;

  // Circuit breaker: if upstream recently 429'd this account, don't call it
  // again until the cooldown passes — serve last-known data instead.
  if (cached && cached.cooldownUntil && now < cached.cooldownUntil) {
    const secs = Math.ceil((cached.cooldownUntil - now) / 1000);
    return serveStale({ status: 429, message: `rate-limited; retrying in ~${secs}s` })
      || { ...base, error: 'rate_limited', message: `rate-limited; retrying in ~${secs}s` };
  }

  // Serve a fresh cache hit without touching upstream.
  if (cached && cached.usage && now - cached.fetchedAt < cacheTtl) {
    return { ...base, usage: cached.usage, cachedAgeMs: now - cached.fetchedAt };
  }

  const storeOk = (u) => { if (cache) cache.set(account.id, { usage: u, fetchedAt: Date.now() }); return u; };
  const tripCooldown = () => { if (cache) cache.set(account.id, { ...(cache.get(account.id) || {}), cooldownUntil: Date.now() + cooldownMs }); };

  try {
    let acct;
    try {
      acct = await ensureFresh(account, { oauth, credstore, locks });
    } catch (e) {
      if (e.needsRelogin) return needsRelogin();
      // Transient refresh failure (network / 5xx): keep last-known data.
      return serveStale({ message: `cached; refresh ${e.status || 'error'}` })
        || { ...base, error: 'fetch_failed', status: e.status || null, message: String(e.message || e) };
    }
    try {
      const u = storeOk(await usage.fetchUsage(acct.accessToken, { thresholds }));
      return { ...base, usage: u };
    } catch (e) {
      // One retry after a forced refresh on 401.
      if (e.status === 401 && acct.refreshToken) {
        try {
          const updated = await refreshAccount(acct, { oauth, credstore, locks });
          const u = storeOk(await usage.fetchUsage(updated.accessToken, { thresholds }));
          return { ...base, usage: u };
        } catch (e2) {
          if (e2.needsRelogin) return needsRelogin();
          return serveStale({ status: e2.status || 401, message: 'cached; re-auth failed' })
            || { ...base, error: 'fetch_failed', status: e2.status || null, message: String(e2.message || e2) };
        }
      }
      // 429 / 5xx / network: prefer last-known value over an error.
      if (e.status === 429) tripCooldown();
      return serveStale({ status: e.status || null, message: `cached; upstream ${e.status || 'error'}` })
        || { ...base, error: e.status === 429 ? 'rate_limited' : 'fetch_failed', status: e.status || null, message: String(e.message || e) };
    }
  } catch (e) {
    return serveStale({ message: 'cached; unexpected error' })
      || { ...base, error: 'unknown', message: String(e.message || e) };
  }
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    req.on('data', (c) => {
      buf += c;
      if (buf.length > 1e6) req.destroy();
    });
    req.on('end', () => {
      try {
        resolve(buf ? JSON.parse(buf) : {});
      } catch {
        resolve({});
      }
    });
  });
}

// deps: { config, credstore, oauth, usage, logins(Map), history }
export function createServer(deps = {}) {
  const config = deps.config || loadConfig();
  const credstore = deps.credstore || createCredStore(config.keychainService);
  const oauth = deps.oauth || oauthLib;
  const usage = deps.usage || usageLib;
  const logins = deps.logins || new Map(); // loginId -> {verifier, state, label}
  const usageCache = deps.usageCache || new Map(); // accountId -> {usage, fetchedAt}
  const refreshLocks = deps.refreshLocks || new Map(); // accountId -> in-flight refresh promise
  const thresholds = { warnPct: config.warnPct, critPct: config.critPct };
  // Usage history store (null when no dir is configured, e.g. in tests).
  const history = deps.history !== undefined ? deps.history
    : (config.historyDir ? createHistory({ dir: config.historyDir, retentionDays: config.historyRetentionDays, log: (m) => console.log(`[history] ${m}`) }) : null);

  // The same aggregate GET /api/usage returns; also what the history poller logs.
  const collectUsage = async () => {
    const accounts = await credstore.listAccounts();
    const results = await Promise.all(
      accounts.map((a) => accountUsage(a, { oauth, credstore, usage, thresholds, cache: usageCache, locks: refreshLocks, cacheTtl: config.cacheTtlMs, cooldownMs: config.rateLimitCooldownMs })),
    );
    // `fleet` folds every account into one capacity-weighted picture (see src/fleet.mjs).
    return { generatedAt: new Date().toISOString(), thresholds, accounts: results, fleet: computeFleet(results, thresholds) };
  };

  // Shared query parsing for the history routes.
  const historyQuery = (url) => {
    const now = Date.now();
    const q = url.searchParams;
    const since = parseTime(q.get('since') || '24h', now);
    const until = parseTime(q.get('until'), now) ?? now;
    if (since == null) return { error: 'bad since (use 24h, 7d, or an ISO time)' };
    return { account: q.get('account') || null, since, until, step: parseStep(q.get('step')), limit: q.has('limit') ? Number(q.get('limit')) : 5000, now };
  };

  const handler = async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;
    try {
      if (req.method === 'GET' && (path === '/' || path === '/index.html')) {
        const html = await readFile(join(WEB_DIR, 'index.html'), 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(html);
      }

      // The fleet aggregation module, shared with the browser so the page can
      // recompute countdowns and demo data with the exact server logic.
      if (req.method === 'GET' && path === '/fleet.mjs') {
        const js = await readFile(join(__dirname, 'fleet.mjs'), 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'no-store' });
        return res.end(js);
      }

      if (req.method === 'GET' && path === '/api/usage') {
        return sendJson(res, 200, await collectUsage());
      }

      // Usage history (written by the background poller). Filters: account
      // (id or label substring), since/until (24h, 7d, ISO), step (downsample:
      // one sample per account per bucket, e.g. 1h), limit (most recent N).
      // format=json (default) | jsonl | csv.
      if (req.method === 'GET' && path === '/api/history') {
        if (!history) return sendJson(res, 404, { error: 'history disabled' });
        const q = historyQuery(url);
        if (q.error) return sendJson(res, 400, { error: q.error });
        const records = await history.query(q);
        const format = url.searchParams.get('format') || 'json';
        if (format === 'jsonl') {
          res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' });
          return res.end(records.map((r) => JSON.stringify(r)).join('\n') + (records.length ? '\n' : ''));
        }
        if (format === 'csv') {
          res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Cache-Control': 'no-store' });
          return res.end(toCsv(records));
        }
        return sendJson(res, 200, {
          since: new Date(q.since).toISOString(), until: new Date(q.until).toISOString(),
          step: url.searchParams.get('step') || null, count: records.length, dir: history.dir, records,
        });
      }

      // Per-account statistics over the same window: samples, min/max/avg/latest
      // for session + weekly, per-model, overage delta, time spent at limit.
      if (req.method === 'GET' && path === '/api/history/summary') {
        if (!history) return sendJson(res, 404, { error: 'history disabled' });
        const q = historyQuery(url);
        if (q.error) return sendJson(res, 400, { error: q.error });
        const records = await history.query({ ...q, limit: 0 });
        return sendJson(res, 200, {
          since: new Date(q.since).toISOString(), until: new Date(q.until).toISOString(),
          samples: records.length, intervalMs: config.historyIntervalMs ?? null, thresholds,
          accounts: summarize(records, thresholds),
        });
      }

      if (req.method === 'GET' && path === '/api/accounts') {
        const accounts = await credstore.listAccounts();
        return sendJson(res, 200, accounts.map((a) => ({ id: a.id, label: a.label, tier: a.tier || null, expiresAt: a.expiresAt || null })));
      }

      if (req.method === 'POST' && path === '/api/login/start') {
        const { label, replaceId } = await readBody(req);
        const { verifier, challenge } = oauth.generatePkce();
        const state = oauth.generateState();
        const loginId = newAccountId();
        logins.set(loginId, { verifier, state, label: label || 'Account', replaceId: replaceId || null });
        const authorizeUrl = oauth.buildAuthorizeUrl({ challenge, state, oauth: config.oauth });
        return sendJson(res, 200, { loginId, authorizeUrl });
      }

      if (req.method === 'POST' && path === '/api/login/finish') {
        const { loginId, pastedCode } = await readBody(req);
        const pending = logins.get(loginId);
        if (!pending) return sendJson(res, 400, { error: 'unknown loginId' });
        const { code, state } = oauth.parsePastedCode(pastedCode);
        if (!code) return sendJson(res, 400, { error: 'no code found in pasted value' });
        if (state && pending.state && state !== pending.state) {
          return sendJson(res, 400, { error: 'state mismatch' });
        }
        let tokens;
        try {
          tokens = await oauth.exchangeCode({ code, state: state || pending.state, verifier: pending.verifier, oauth: config.oauth });
        } catch (e) {
          return sendJson(res, 400, { error: 'exchange_failed', message: String(e.message || e) });
        }
        logins.delete(loginId);
        // Re-login replaces the existing account in place (no duplicate).
        const id = pending.replaceId || newAccountId();
        // Auto-label from the account profile (email + plan); best-effort.
        let label = pending.label && pending.label !== 'Account' ? pending.label : null;
        let tier = null;
        try {
          const profile = await usage.fetchProfile(tokens.accessToken);
          label = label || profile.email || 'Account';
          tier = profile.tier;
        } catch {
          label = label || 'Account';
        }
        await credstore.putAccount({
          id,
          label,
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: tokens.expiresAt,
          tier,
        });
        // Clear any stale cache / cooldown / in-flight lock for this account.
        usageCache.delete(id);
        refreshLocks.delete(id);
        return sendJson(res, 200, { ok: true, id, label });
      }

      if (req.method === 'DELETE' && path.startsWith('/api/accounts/')) {
        const id = decodeURIComponent(path.split('/').pop());
        await credstore.deleteAccount(id);
        return sendJson(res, 200, { ok: true });
      }

      sendJson(res, 404, { error: 'not found' });
    } catch (e) {
      sendJson(res, 500, { error: 'server_error', message: String(e.message || e) });
    }
  };

  const server = http.createServer(handler);
  return { server, handler, config, credstore, logins, refreshLocks, history, collectUsage };
}

// Entry point when run directly.
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const { server, handler, config, credstore, refreshLocks, history, collectUsage } = createServer();
  server.listen(config.port, config.bindHost, () => {
    console.log(`Craig's Claude Counter listening on http://${config.bindHost}:${config.port}`);
  });
  // Also serve on loopback so localhost + the CLI work, without exposing the LAN.
  if (config.bindHost !== '127.0.0.1') {
    http.createServer(handler).listen(config.port, '127.0.0.1', () => {
      console.log(`Also on http://127.0.0.1:${config.port} (local)`);
    });
  }
  // Keep accounts logged in even when nobody is viewing the dashboard.
  startBackgroundRefresh({
    credstore,
    oauth: oauthLib,
    locks: refreshLocks,
    intervalMs: config.bgRefreshIntervalMs,
    refreshWithinMs: config.bgRefreshWithinMs,
    log: (m) => console.log(`[keepalive] ${m}`),
  });
  // Log every account's limits on an interval so there is a record over time
  // even when no dashboard is open (see src/history.mjs, GET /api/history).
  if (history && config.historyIntervalMs > 0) {
    startUsagePoller({
      collect: collectUsage,
      history,
      intervalMs: config.historyIntervalMs,
      log: (m) => console.log(`[history] ${m}`),
    });
    console.log(`[history] logging every ${Math.round(config.historyIntervalMs / 1000)}s to ${history.dir} (keep ${config.historyRetentionDays}d)`);
  }
}
