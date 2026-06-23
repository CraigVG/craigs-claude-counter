import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, ensureFresh } from '../src/server.mjs';
import { OAUTH } from '../src/config.mjs';

function memStore(seed = []) {
  const m = new Map(seed.map((a) => [a.id, a]));
  return {
    putCalls: [],
    async listAccounts() { return [...m.values()]; },
    async getAccount(id) { return m.get(id) || null; },
    async putAccount(a) { this.putCalls.push(a); m.set(a.id, a); return a; },
    async deleteAccount(id) { m.delete(id); },
  };
}

const baseConfig = { warnPct: 70, critPct: 90, oauth: OAUTH, keychainService: 'test' };

async function boot(deps) {
  const { server } = createServer({ config: baseConfig, ...deps });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  return { base: `http://127.0.0.1:${port}`, close: () => new Promise((r) => server.close(r)) };
}

const goodUsage = { session: { pct: 50, severity: 'normal', resetsAt: 'x' }, weekly: { pct: 60, severity: 'normal', resetsAt: 'y' } };

test('/api/usage aggregates and isolates per-account failures', async () => {
  const credstore = memStore([
    { id: 'ok', label: 'ok@x', tier: 'Max 20x', accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 },
    { id: 'bad', label: 'bad@x', accessToken: 'AT2', refreshToken: 'RT2', expiresAt: Date.now() + 3600_000 },
  ]);
  const usage = {
    fetchUsage: async (tok) => { if (tok === 'AT2') { const e = new Error('boom'); e.status = 500; throw e; } return goodUsage; },
  };
  const oauth = { refresh: async () => { throw new Error('should not refresh fresh token'); } };
  const { base, close } = await boot({ credstore, usage, oauth });
  try {
    const r = await fetch(base + '/api/usage');
    const body = await r.json();
    assert.equal(body.accounts.length, 2);
    const ok = body.accounts.find((a) => a.id === 'ok');
    const bad = body.accounts.find((a) => a.id === 'bad');
    assert.equal(ok.usage.session.pct, 50);
    assert.equal(ok.tier, 'Max 20x');
    assert.equal(bad.error, 'fetch_failed');
    assert.equal(bad.status, 500);
  } finally { await close(); }
});

test('ensureFresh refreshes a near-expiry token and persists it', async () => {
  const credstore = memStore();
  const oauth = { refresh: async ({ refreshToken }) => ({ accessToken: 'NEW', refreshToken: refreshToken + '+', expiresAt: Date.now() + 3600_000 }) };
  const account = { id: 'a', label: 'a', accessToken: 'OLD', refreshToken: 'RT', expiresAt: Date.now() + 1000 }; // ~expired
  const out = await ensureFresh(account, { oauth, credstore });
  assert.equal(out.accessToken, 'NEW');
  assert.equal(credstore.putCalls.length, 1);
  assert.equal(credstore.putCalls[0].accessToken, 'NEW');
});

test('ensureFresh leaves a fresh token untouched', async () => {
  const credstore = memStore();
  const oauth = { refresh: async () => { throw new Error('nope'); } };
  const account = { id: 'a', accessToken: 'OK', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 };
  const out = await ensureFresh(account, { oauth, credstore });
  assert.equal(out.accessToken, 'OK');
  assert.equal(credstore.putCalls.length, 0);
});

test('401 on usage triggers one refresh-and-retry', async () => {
  let calls = 0;
  const credstore = memStore([{ id: 'a', label: 'a@x', accessToken: 'OLD', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }]);
  const usage = { fetchUsage: async (tok) => { calls++; if (tok === 'OLD') { const e = new Error('401'); e.status = 401; throw e; } return goodUsage; } };
  const oauth = { refresh: async () => ({ accessToken: 'FRESH', refreshToken: 'RT2', expiresAt: Date.now() + 3600_000 }) };
  const { base, close } = await boot({ credstore, usage, oauth });
  try {
    const r = await fetch(base + '/api/usage');
    const body = await r.json();
    assert.equal(body.accounts[0].usage.session.pct, 50);
    assert.equal(calls, 2); // first 401, retry success
  } finally { await close(); }
});

test('login start -> finish creates an account', async () => {
  const credstore = memStore();
  const oauth = {
    generatePkce: () => ({ verifier: 'V', challenge: 'C' }),
    generateState: () => 'STATE',
    buildAuthorizeUrl: () => 'https://claude.ai/oauth/authorize?x=1',
    parsePastedCode: (s) => ({ code: s.split('#')[0], state: s.split('#')[1] || null }),
    exchangeCode: async () => ({ accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }),
  };
  const usage = { fetchProfile: async () => ({ email: 'new@x.com', tier: 'Max 5x' }) };
  const { base, close } = await boot({ credstore, oauth, usage });
  try {
    const s = await (await fetch(base + '/api/login/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ label: '' }) })).json();
    assert.ok(s.loginId);
    assert.ok(s.authorizeUrl.startsWith('https://claude.ai'));
    const f = await (await fetch(base + '/api/login/finish', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ loginId: s.loginId, pastedCode: 'thecode#STATE' }) })).json();
    assert.equal(f.ok, true);
    assert.equal(f.label, 'new@x.com');
    const list = await credstore.listAccounts();
    assert.equal(list.length, 1);
    assert.equal(list[0].tier, 'Max 5x');
  } finally { await close(); }
});

test('login finish rejects state mismatch', async () => {
  const credstore = memStore();
  const oauth = {
    generatePkce: () => ({ verifier: 'V', challenge: 'C' }),
    generateState: () => 'RIGHT',
    buildAuthorizeUrl: () => 'https://claude.ai/oauth/authorize',
    parsePastedCode: (s) => ({ code: s.split('#')[0], state: s.split('#')[1] || null }),
    exchangeCode: async () => { throw new Error('should not exchange'); },
  };
  const { base, close } = await boot({ credstore, oauth, usage: {} });
  try {
    const s = await (await fetch(base + '/api/login/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })).json();
    const r = await fetch(base + '/api/login/finish', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ loginId: s.loginId, pastedCode: 'code#WRONG' }) });
    assert.equal(r.status, 400);
    const body = await r.json();
    assert.equal(body.error, 'state mismatch');
  } finally { await close(); }
});

test('DELETE /api/accounts/:id removes the account', async () => {
  const credstore = memStore([{ id: 'gone', label: 'g', accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }]);
  const { base, close } = await boot({ credstore, usage: {}, oauth: {} });
  try {
    const r = await fetch(base + '/api/accounts/gone', { method: 'DELETE' });
    assert.equal((await r.json()).ok, true);
    assert.equal((await credstore.listAccounts()).length, 0);
  } finally { await close(); }
});

async function bootCfg(deps, cfgOverride = {}) {
  const { server } = createServer({ config: { ...baseConfig, ...cfgOverride }, ...deps });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  return { base: `http://127.0.0.1:${port}`, close: () => new Promise((r) => server.close(r)) };
}

test('usage is cached within TTL (repeated polls hit upstream once)', async () => {
  let calls = 0;
  const credstore = memStore([{ id: 'a', label: 'a@x', accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }]);
  const usage = { fetchUsage: async () => { calls++; return goodUsage; } };
  const oauth = { refresh: async () => { throw new Error('no'); } };
  const { base, close } = await bootCfg({ credstore, usage, oauth }, { cacheTtlMs: 60_000 });
  try {
    await fetch(base + '/api/usage');
    await fetch(base + '/api/usage');
    const body = await (await fetch(base + '/api/usage')).json();
    assert.equal(calls, 1); // 3 polls, 1 upstream call
    assert.ok(body.accounts[0].cachedAgeMs >= 0);
    assert.equal(body.accounts[0].usage.session.pct, 50);
  } finally { await close(); }
});

test('serves stale cached value when upstream 429s', async () => {
  let calls = 0;
  const credstore = memStore([{ id: 'a', label: 'a@x', accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }]);
  const usage = { fetchUsage: async () => { calls++; if (calls === 1) return goodUsage; const e = new Error('429'); e.status = 429; throw e; } };
  const oauth = { refresh: async () => { throw new Error('no'); } };
  const { base, close } = await bootCfg({ credstore, usage, oauth }, { cacheTtlMs: 0 }); // force refetch each poll
  try {
    await fetch(base + '/api/usage'); // success -> cached
    const body = await (await fetch(base + '/api/usage')).json(); // 429 -> stale
    assert.equal(body.accounts[0].stale, true);
    assert.equal(body.accounts[0].usage.session.pct, 50);
    assert.equal(body.accounts[0].error, undefined);
  } finally { await close(); }
});

test('circuit breaker stops calling upstream during a 429 cooldown', async () => {
  let calls = 0;
  const credstore = memStore([{ id: 'a', label: 'a@x', accessToken: 'AT', refreshToken: 'RT', expiresAt: Date.now() + 3600_000 }]);
  const usage = { fetchUsage: async () => { calls++; if (calls === 1) return goodUsage; const e = new Error('429'); e.status = 429; throw e; } };
  const oauth = { refresh: async () => { throw new Error('no'); } };
  const { base, close } = await bootCfg({ credstore, usage, oauth }, { cacheTtlMs: 0, rateLimitCooldownMs: 60_000 });
  try {
    await fetch(base + '/api/usage'); // success -> cache
    await fetch(base + '/api/usage'); // 429 -> trips cooldown
    const body = await (await fetch(base + '/api/usage')).json(); // cooldown -> NO upstream call
    assert.equal(calls, 2);
    assert.equal(body.accounts[0].stale, true);
    assert.match(body.accounts[0].message, /rate-limited/);
  } finally { await close(); }
});

test('single-flight: concurrent refreshes share one upstream refresh call', async () => {
  let calls = 0;
  const credstore = memStore();
  const oauth = { refresh: async ({ refreshToken }) => { calls++; await new Promise((r) => setTimeout(r, 20)); return { accessToken: 'NEW', refreshToken: refreshToken + '+', expiresAt: Date.now() + 3600_000 }; } };
  const locks = new Map();
  const account = { id: 'a', accessToken: 'OLD', refreshToken: 'RT', expiresAt: Date.now() + 1000 }; // near expiry -> needs refresh
  const results = await Promise.all([
    ensureFresh(account, { oauth, credstore, locks }),
    ensureFresh(account, { oauth, credstore, locks }),
    ensureFresh(account, { oauth, credstore, locks }),
  ]);
  assert.equal(calls, 1); // 3 concurrent callers, ONE refresh (no token reuse)
  assert.ok(results.every((r) => r.accessToken === 'NEW'));
});

test('permanent refresh failure (400) surfaces needs_relogin with dimmed last-known data', async () => {
  const credstore = memStore([{ id: 'a', label: 'a@x', accessToken: 'OLD', refreshToken: 'RT', expiresAt: Date.now() - 1000 }]); // expired
  const usage = { fetchUsage: async () => goodUsage };
  const oauth = { refresh: async () => { const e = new Error('invalid_grant'); e.status = 400; throw e; } };
  const usageCache = new Map([['a', { usage: goodUsage, fetchedAt: Date.now() - 10 * 60_000 }]]); // stale cache present
  const { server } = createServer({ config: baseConfig, credstore, usage, oauth, usageCache });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  try {
    const body = await (await fetch(`http://127.0.0.1:${port}/api/usage`)).json();
    const acc = body.accounts[0];
    assert.equal(acc.error, 'needs_relogin'); // not silently served as fresh/stale
    assert.ok(acc.usage); // still includes last-known numbers for the dimmed display
  } finally { await new Promise((r) => server.close(r)); }
});

test('GET / serves the dashboard html', async () => {
  const { base, close } = await boot({ credstore: memStore(), usage: {}, oauth: {} });
  try {
    const r = await fetch(base + '/');
    assert.equal(r.status, 200);
    const html = await r.text();
    assert.match(html, /Claude.+Code Usage/);
  } finally { await close(); }
});
