// Gemini usage, read through the Antigravity CLI (`agy`): `agy -p /usage`
// with JSON output answers from the CLI itself (no model turn, no tokens)
// with the plan's quota groups. The "Gemini Models" group has a weekly bucket
// and, on paid plans, a 5-hour bucket, each as a remaining fraction and a
// reset time. The Google login stays inside agy; this engine never sees it.
//
// Shaped like the Codex entry (src/codex.mjs) and served the same way:
// `gemini` in /api/usage, apart from `accounts`. agy reports neither the
// account's email nor its plan name.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { severityFor } from './usage.mjs';
import { createCliSource } from './codex.mjs';

export function findAgyBin(env = process.env, exists = existsSync) {
  if (env.CLAUDE_USAGE_GEMINI_BIN) return env.CLAUDE_USAGE_GEMINI_BIN;
  const home = homedir();
  const candidates = [join(home, '.local/bin/agy'), '/opt/homebrew/bin/agy', '/usr/local/bin/agy'];
  return candidates.find((p) => exists(p)) || 'agy';
}

function win(b, thresholds, windowMins) {
  if (!b || b.remaining_fraction == null || Number.isNaN(Number(b.remaining_fraction))) return null;
  const pct = Math.round(Math.max(0, Math.min(100, (1 - Number(b.remaining_fraction)) * 100)) * 10) / 10;
  const t = b.reset_time ? Date.parse(b.reset_time) : NaN;
  return { pct, resetsAt: Number.isNaN(t) ? null : new Date(t).toISOString(), severity: severityFor(pct, thresholds?.warnPct, thresholds?.critPct), active: pct > 0, windowMins };
}

// agy's /usage result -> an account entry. Throws when the result has no
// Gemini weekly bucket (an agy that does not know /usage sends the text to a
// model instead; that costs tokens, so the caller waits hours before a retry).
export function geminiEntry(result, thresholds) {
  const groups = result?.command?.data?.groups;
  const buckets = Array.isArray(groups) ? groups.flatMap((g) => g.buckets || []) : [];
  const weeklyB = buckets.find((b) => b.id === 'gemini-weekly');
  if (!weeklyB) throw Object.assign(new Error('agy reported no Gemini quota'), { retryMs: 6 * 3_600_000 });
  const weekly = win(weeklyB, thresholds, 7 * 24 * 60);
  const session = win(buckets.find((b) => b.id === 'gemini-5h'), thresholds, 5 * 60);
  const out = [weekly, session].find((w) => w && w.pct >= 100);
  return {
    id: 'gemini:default',
    provider: 'gemini',
    label: 'Gemini',
    email: null,
    tier: 'Gemini',
    usage: { session, weekly, weeklyModels: [], overage: null, credits: null, limitReached: out ? (out === weekly ? 'weekly' : '5h') : null },
  };
}

// Run `agy --output-format json -p /usage` once and parse its JSON. Rejects
// when agy is missing, not signed in, slow, or prints something else.
export function readGemini({ bin = findAgyBin(), timeoutMs = 20_000, spawnImpl = spawn } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, PATH: [dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', process.env.PATH || ''].join(':') };
    let child;
    // From the home directory, so agy does not register this repo as a workspace.
    try { child = spawnImpl(bin, ['--output-format', 'json', '--print-timeout', '15s', '-p', '/usage'], { stdio: ['ignore', 'pipe', 'ignore'], env, cwd: homedir() }); } catch (e) { reject(e); return; }
    let buf = '';
    let done = false;
    const finish = (err, val) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { child.kill(); } catch { /* already gone */ }
      if (err) reject(err); else resolve(val);
    };
    const timer = setTimeout(() => finish(new Error('agy timed out')), timeoutMs);
    child.on('error', (e) => finish(e.code === 'ENOENT' ? Object.assign(new Error('agy not found'), { code: 'ENOENT' }) : e));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (c) => { buf += c; });
    child.on('close', () => {
      let out;
      try { out = JSON.parse(buf); } catch { finish(new Error('agy printed no JSON (not signed in?)')); return; }
      if (out.status && out.status !== 'SUCCESS') { finish(new Error(String(out.error || out.status).slice(0, 120))); return; }
      finish(null, out);
    });
  });
}

export function createGeminiSource({ read = readGemini, ttlMs = 180_000, thresholds, random = Math.random, log = () => {} } = {}) {
  return createCliSource({ read, entryFrom: (out) => geminiEntry(out, thresholds), tag: 'gemini', ttlMs, random, log });
}
