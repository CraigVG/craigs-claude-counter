import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { findAgyBin, geminiEntry, readGemini, createGeminiSource } from '../src/gemini.mjs';
import { tierWeight, computeFleet } from '../src/fleet.mjs';

const live = {
  status: 'SUCCESS',
  command: { name: 'usage', data: { groups: [
    { name: 'Gemini Models', buckets: [
      { id: 'gemini-weekly', window: 'weekly', remaining_fraction: 0.75, reset_time: '2026-11-30T20:23:59Z' },
      { id: 'gemini-5h', window: '5h', remaining_fraction: 0.9, reset_time: '2026-11-24T01:23:59Z' }] },
    { name: 'Claude and GPT models', buckets: [{ id: '3p-weekly', window: 'weekly', remaining_fraction: 0.1, reset_time: '2026-11-30T22:16:24Z' }] },
  ] } },
};

test('geminiEntry turns remaining fractions into used percent, from the Gemini group only', () => {
  const e = geminiEntry(live);
  assert.equal(e.id, 'gemini:default');
  assert.equal(e.provider, 'gemini');
  assert.equal(e.usage.weekly.pct, 25);
  assert.equal(e.usage.weekly.resetsAt, '2026-11-30T20:23:59.000Z');
  assert.equal(e.usage.session.pct, 10);
  assert.equal(e.usage.limitReached, null);
});

test('a plan with no 5-hour bucket has no session window; an empty bucket is a reached limit', () => {
  const g = structuredClone(live);
  g.command.data.groups[0].buckets = [{ id: 'gemini-weekly', remaining_fraction: 0, reset_time: '2026-11-30T20:23:59Z' }];
  const e = geminiEntry(g);
  assert.equal(e.usage.session, null);
  assert.equal(e.usage.weekly.pct, 100);
  assert.equal(e.usage.limitReached, 'weekly');
});

test('a result with no usage data is refused with a long retry wait', () => {
  assert.throws(() => geminiEntry({ status: 'SUCCESS', response: 'some model text' }), (e) => e.retryMs >= 3_600_000);
});

test('Gemini weighs 1 in the fleet unless the setting says otherwise', () => {
  assert.deepEqual(tierWeight('Gemini'), { weight: 1, assumed: false });
  assert.equal(tierWeight('Gemini', { gemini: 3.5 }).weight, 3.5);
  const claude = { id: 'a', tier: 'Max 20x', usage: { session: { pct: 0 }, weekly: { pct: 0 } } };
  assert.equal(computeFleet([claude, geminiEntry(live)]).weightTotal, 8);
});

test('createGeminiSource hides Gemini when agy fails and does not run agy again before the retry time', async () => {
  let runs = 0, t = 1_000_000;
  const realNow = Date.now; Date.now = () => t;
  try {
    const src = createGeminiSource({ read: async () => { runs++; return { status: 'SUCCESS', response: 'not usage' }; } });
    assert.deepEqual(await src.get(), []);
    t += 3_600_000;
    assert.deepEqual(await src.get(), []);
    assert.equal(runs, 1, 'no second run inside the six-hour wait');
    const ok = createGeminiSource({ read: async () => live, random: () => 0.5 });
    assert.equal((await ok.get())[0].usage.weekly.pct, 25);
  } finally { Date.now = realNow; }
});

test('findAgyBin honours the override and falls back to the name', () => {
  assert.equal(findAgyBin({ CLAUDE_USAGE_GEMINI_BIN: '/x/agy' }, () => false), '/x/agy');
  assert.equal(findAgyBin({}, () => false), 'agy');
});

function fakeSpawn(stdoutText) {
  const calls = [];
  const impl = (bin, args, opts) => {
    calls.push({ bin, args, opts });
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.kill = () => {};
    setImmediate(() => { child.stdout.end(stdoutText); child.emit('close', 0); });
    return child;
  };
  return { impl, calls };
}

test('readGemini runs agy /usage in JSON print mode and rejects an auth error', async () => {
  const ok = fakeSpawn(JSON.stringify(live));
  const out = await readGemini({ bin: '/x/agy', spawnImpl: ok.impl });
  assert.equal(out.command.name, 'usage');
  assert.deepEqual(ok.calls[0].args.slice(-2), ['-p', '/usage']);
  assert.ok(ok.calls[0].args.includes('json'));
  const bad = fakeSpawn(JSON.stringify({ status: 'ERROR', error: 'authentication failed or timed out' }));
  await assert.rejects(readGemini({ bin: '/x/agy', spawnImpl: bad.impl }), /authentication failed/);
  const none = fakeSpawn('Error: authentication required.');
  await assert.rejects(readGemini({ bin: '/x/agy', spawnImpl: none.impl }), /no JSON/);
});
