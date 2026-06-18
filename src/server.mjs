// Tiny HTTP server: serves the dashboard page and a small JSON API.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadConfig, REFRESH_SKEW_MS } from './config.mjs';
import { createCredStore, newAccountId } from './credstore.mjs';
import * as oauthLib from './oauth.mjs';
import * as usageLib from './usage.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WEB_DIR = join(__dirname, '..', 'web');

// Refresh an account's token if it is missing or close to expiry. Persists the
// new token via credstore.putAccount. Returns the (possibly updated) account.
export async function ensureFresh(account, { oauth, credstore, now = Date.now(), skewMs = REFRESH_SKEW_MS }) {
  const fresh = account.expiresAt && account.expiresAt - now > skewMs;
  if (fresh) return account;
  if (!account.refreshToken) {
    const err = new Error('no refresh token');
    err.needsRelogin = true;
    throw err;
  }
  const tokens = await oauth.refresh({ refreshToken: account.refreshToken });
  const updated = {
    ...account,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken || account.refreshToken,
    expiresAt: tokens.expiresAt,
  };
  await credstore.putAccount(updated);
  return updated;
}

// Build the aggregate payload for one account, isolating all failures.
async function accountUsage(account, deps) {
  const { oauth, credstore, usage, thresholds } = deps;
  const base = { id: account.id, label: account.label, tier: account.tier || null };
  try {
    let acct;
    try {
      acct = await ensureFresh(account, { oauth, credstore });
    } catch (e) {
      return { ...base, error: 'needs_relogin', message: String(e.message || e) };
    }
    try {
      const u = await usage.fetchUsage(acct.accessToken, { thresholds });
      return { ...base, usage: u };
    } catch (e) {
      // One retry after a forced refresh on 401.
      if (e.status === 401 && acct.refreshToken) {
        try {
          const tokens = await oauth.refresh({ refreshToken: acct.refreshToken });
          const updated = { ...acct, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken || acct.refreshToken, expiresAt: tokens.expiresAt };
          await credstore.putAccount(updated);
          const u = await usage.fetchUsage(updated.accessToken, { thresholds });
          return { ...base, usage: u };
        } catch (e2) {
          return { ...base, error: 'needs_relogin', message: String(e2.message || e2) };
        }
      }
      return { ...base, error: 'fetch_failed', status: e.status || null, message: String(e.message || e) };
    }
  } catch (e) {
    return { ...base, error: 'unknown', message: String(e.message || e) };
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

// deps: { config, credstore, oauth, usage, logins(Map) }
export function createServer(deps = {}) {
  const config = deps.config || loadConfig();
  const credstore = deps.credstore || createCredStore(config.keychainService);
  const oauth = deps.oauth || oauthLib;
  const usage = deps.usage || usageLib;
  const logins = deps.logins || new Map(); // loginId -> {verifier, state, label}
  const thresholds = { warnPct: config.warnPct, critPct: config.critPct };

  const handler = async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;
    try {
      if (req.method === 'GET' && (path === '/' || path === '/index.html')) {
        const html = await readFile(join(WEB_DIR, 'index.html'), 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(html);
      }

      if (req.method === 'GET' && path === '/api/usage') {
        const accounts = await credstore.listAccounts();
        const results = await Promise.all(
          accounts.map((a) => accountUsage(a, { oauth, credstore, usage, thresholds })),
        );
        return sendJson(res, 200, {
          generatedAt: new Date().toISOString(),
          thresholds,
          accounts: results,
        });
      }

      if (req.method === 'GET' && path === '/api/accounts') {
        const accounts = await credstore.listAccounts();
        return sendJson(res, 200, accounts.map((a) => ({ id: a.id, label: a.label, tier: a.tier || null, expiresAt: a.expiresAt || null })));
      }

      if (req.method === 'POST' && path === '/api/login/start') {
        const { label } = await readBody(req);
        const { verifier, challenge } = oauth.generatePkce();
        const state = oauth.generateState();
        const loginId = newAccountId();
        logins.set(loginId, { verifier, state, label: label || 'Account' });
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
        const id = newAccountId();
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
  return { server, handler, config, credstore, logins };
}

// Entry point when run directly.
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const { server, handler, config } = createServer();
  server.listen(config.port, config.bindHost, () => {
    console.log(`Claude Usage Dashboard listening on http://${config.bindHost}:${config.port}`);
  });
  // Also serve on loopback so localhost + the CLI work, without exposing the LAN.
  if (config.bindHost !== '127.0.0.1') {
    http.createServer(handler).listen(config.port, '127.0.0.1', () => {
      console.log(`Also on http://127.0.0.1:${config.port} (local)`);
    });
  }
}
