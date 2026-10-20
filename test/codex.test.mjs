import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { codexEntry, codexTier, createCodexSource, readCodex } from '../src/codex.mjs';
import { tierWeight, computeFleet, DEFAULT_WEIGHTS } from '../src/fleet.mjs';

const live = {
  account: { type: 'chatgpt', email: 'craig@example.com', planType: 'pro' },
  rateLimits: {
    accountId: 'acct-1', planType: 'pro', ordinaryUsageAllowed: true,
    primary: { usedPercent: 7, windowDurationMins: 10080, resetsAt: 1793082774 },
    secondary: null,
    credits: { hasCredits: true, unlimited: false, balance: '46491.5797560000' },
  },
};

test('codexEntry maps the weekly window, an optional 5h window and credits', () => {
  const e = codexEntry(live);
  assert.equal(e.id, 'codex:acct-1');
  assert.equal(e.provider, 'codex');
  assert.equal(e.label, 'Codex · craig@example.com');
  assert.equal(e.tier, 'Codex Pro');
  assert.equal(e.usage.weekly.pct, 7);
  assert.equal(e.usage.weekly.resetsAt, new Date(1793082774 * 1000).toISOString());
  assert.equal(e.usage.session, null);
  assert.equal(e.usage.credits.balance, 46491.579756);
  const both = codexEntry({ ...live, rateLimits: { ...live.rateLimits, primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 1793000000 }, secondary: { usedPercent: 12, windowDurationMins: 10080, resetsAt: 1793082774 } } });
  assert.equal(both.usage.session.pct, 40);
  assert.equal(both.usage.weekly.pct, 12);
  assert.equal(codexTier('plus'), 'Codex Plus');
});

test('a Codex Pro week counts like Max 20x, never like Claude Pro, and the override wins', () => {
  assert.equal(tierWeight('Codex Pro').weight, 7);
  assert.equal(tierWeight('Codex Plus').weight, 1);
  assert.equal(tierWeight('Pro').weight, 1);
  assert.equal(tierWeight('Codex Pro', { ...DEFAULT_WEIGHTS, codex: 3.5 }).weight, 3.5);
  const claude = { id: 'c', label: 'c', tier: 'Pro', usage: { session: { pct: 0 }, weekly: { pct: 100, resetsAt: null } } };
  const f = computeFleet([claude, codexEntry(live)]);
  assert.equal(f.weightTotal, 8);
  assert.equal(f.usedPct, Math.round(((100 * 1 + 7 * 7) / 8) * 10) / 10);
});

test('createCodexSource caches, shares one run, serves stale on failure, and hides Codex when absent', async () => {
  let runs = 0, fail = false;
  const read = async () => { runs++; await new Promise((r) => setTimeout(r, 5)); if (fail) throw new Error('boom'); return live; };
  const src = createCodexSource({ read, ttlMs: 60_000, random: () => 0.5 });
  const [a, b] = await Promise.all([src.get(), src.get()]);
  assert.equal(runs, 1);
  assert.equal(a[0].usage.weekly.pct, 7);
  assert.deepEqual(a, b);
  await src.get();
  assert.equal(runs, 1, 'cached');
  const src2 = createCodexSource({ read: async () => { throw Object.assign(new Error('x'), { code: 'ENOENT' }); } });
  assert.deepEqual(await src2.get(), []);
  assert.equal(src2.status().unavailable, 'codex CLI not found');
  const src3 = createCodexSource({ read: async () => { if (fail) throw new Error('timed out'); return live; }, ttlMs: 0 });
  await src3.get();
  fail = true;
  const stale = await src3.get();
  assert.equal(stale[0].stale, true);
  assert.match(stale[0].message, /timed out/);
});

test('readCodex speaks JSON-RPC to the app server and stops it', async () => {
  let killed = false;
  const spawnImpl = () => {
    const child = new EventEmitter();
    child.stdin = new PassThrough(); child.stdout = new PassThrough();
    child.kill = () => { killed = true; };
    child.stdin.on('data', (d) => {
      for (const line of String(d).split('\n').filter(Boolean)) {
        const m = JSON.parse(line);
        const result = m.method === 'initialize' ? {} : m.method === 'account/read' ? { account: live.account } : { rateLimits: live.rateLimits };
        child.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, result }) + '\n');
      }
    });
    return child;
  };
  const out = await readCodex({ bin: 'codex', spawnImpl, timeoutMs: 2000 });
  assert.equal(out.account.email, 'craig@example.com');
  assert.equal(out.rateLimits.primary.usedPercent, 7);
  assert.equal(killed, true);
});
