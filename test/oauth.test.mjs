import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  generatePkce, generateState, buildAuthorizeUrl, parsePastedCode,
  parseTokenResponse, exchangeCode, refresh,
} from '../src/oauth.mjs';

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

test('generatePkce produces a valid S256 challenge', () => {
  const { verifier, challenge } = generatePkce();
  assert.match(verifier, /^[A-Za-z0-9_-]+$/);
  const expected = base64url(createHash('sha256').update(verifier).digest());
  assert.equal(challenge, expected);
});

test('generateState is random and url-safe', () => {
  const a = generateState(), b = generateState();
  assert.notEqual(a, b);
  assert.match(a, /^[A-Za-z0-9_-]+$/);
});

test('buildAuthorizeUrl includes required params', () => {
  const url = new URL(buildAuthorizeUrl({ challenge: 'CHAL', state: 'STATE' }));
  assert.equal(url.origin + url.pathname, 'https://claude.ai/oauth/authorize');
  assert.equal(url.searchParams.get('client_id'), '9d1c250a-e61b-44d9-88ed-5944d1962f5e');
  assert.equal(url.searchParams.get('response_type'), 'code');
  assert.equal(url.searchParams.get('code_challenge'), 'CHAL');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('state'), 'STATE');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://platform.claude.com/oauth/code/callback');
  assert.ok(url.searchParams.get('scope').includes('user:inference'));
});

test('parsePastedCode splits code#state', () => {
  assert.deepEqual(parsePastedCode('abc123#st-9'), { code: 'abc123', state: 'st-9' });
  assert.deepEqual(parsePastedCode('  onlycode  '), { code: 'onlycode', state: null });
  assert.deepEqual(parsePastedCode(''), { code: null, state: null });
});

test('parseTokenResponse computes expiresAt and keeps refresh token', () => {
  const now = 1_000_000;
  const t = parseTokenResponse({ access_token: 'AT', refresh_token: 'RT', expires_in: 3600 }, now);
  assert.equal(t.accessToken, 'AT');
  assert.equal(t.refreshToken, 'RT');
  assert.equal(t.expiresAt, now + 3600_000);
});

test('parseTokenResponse throws when access_token missing', () => {
  assert.throws(() => parseTokenResponse({}));
});

test('refresh posts refresh_token grant and parses tokens', async () => {
  let captured;
  const fetchImpl = async (url, opts) => {
    captured = { url, body: JSON.parse(opts.body) };
    return { ok: true, json: async () => ({ access_token: 'NEW', refresh_token: 'NEWR', expires_in: 60 }) };
  };
  const t = await refresh({ refreshToken: 'OLDR' }, { fetchImpl });
  assert.equal(captured.url, 'https://platform.claude.com/v1/oauth/token');
  assert.equal(captured.body.grant_type, 'refresh_token');
  assert.equal(captured.body.refresh_token, 'OLDR');
  assert.equal(captured.body.client_id, '9d1c250a-e61b-44d9-88ed-5944d1962f5e');
  assert.equal(t.accessToken, 'NEW');
});

test('exchangeCode posts authorization_code grant', async () => {
  let body;
  const fetchImpl = async (_url, opts) => {
    body = JSON.parse(opts.body);
    return { ok: true, json: async () => ({ access_token: 'AT', refresh_token: 'RT', expires_in: 3600 }) };
  };
  await exchangeCode({ code: 'C', state: 'S', verifier: 'V' }, { fetchImpl });
  assert.equal(body.grant_type, 'authorization_code');
  assert.equal(body.code, 'C');
  assert.equal(body.code_verifier, 'V');
  assert.equal(body.redirect_uri, 'https://platform.claude.com/oauth/code/callback');
});

test('token endpoint error surfaces status', async () => {
  const fetchImpl = async () => ({ ok: false, status: 400, json: async () => ({ error: 'invalid_grant' }) });
  await assert.rejects(() => refresh({ refreshToken: 'x' }, { fetchImpl }), (e) => e.status === 400);
});
