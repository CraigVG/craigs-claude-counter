// OAuth (PKCE) login + refresh for Claude Code accounts.
import { createHash, randomBytes } from 'node:crypto';
import { OAUTH, USER_AGENT } from './config.mjs';

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// PKCE verifier + S256 challenge.
export function generatePkce() {
  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

export function generateState() {
  return base64url(randomBytes(24));
}

// Build the authorize URL the user opens to log into a specific account.
export function buildAuthorizeUrl({ challenge, state, oauth = OAUTH }) {
  const u = new URL(oauth.authorizeUrl);
  u.searchParams.set('code', 'true');
  u.searchParams.set('client_id', oauth.clientId);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('redirect_uri', oauth.redirectUri);
  u.searchParams.set('scope', oauth.scopes.join(' '));
  u.searchParams.set('code_challenge', challenge);
  u.searchParams.set('code_challenge_method', 'S256');
  u.searchParams.set('state', state);
  return u.toString();
}

// The platform shows a code like "<code>#<state>"; split it.
export function parsePastedCode(input) {
  const trimmed = String(input || '').trim();
  const [code, state] = trimmed.split('#');
  return { code: code || null, state: state || null };
}

// Convert a token-endpoint JSON response into our stored shape.
export function parseTokenResponse(json, now = Date.now()) {
  if (!json || !json.access_token) {
    throw new Error('token response missing access_token');
  }
  const expiresInMs = (json.expires_in ?? 3600) * 1000;
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token ?? null,
    expiresAt: now + expiresInMs,
    scope: json.scope ?? null,
  };
}

async function postToken(body, { fetchImpl = fetch, oauth = OAUTH } = {}) {
  const res = await fetchImpl(oauth.tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': USER_AGENT },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let detail = '';
    try {
      detail = JSON.stringify(await res.json());
    } catch {
      /* ignore */
    }
    const err = new Error(`token endpoint returned ${res.status} ${detail}`);
    err.status = res.status;
    throw err;
  }
  return parseTokenResponse(await res.json());
}

// Exchange an authorization code (+ PKCE verifier) for tokens.
export function exchangeCode({ code, state, verifier, oauth = OAUTH }, opts = {}) {
  return postToken(
    {
      grant_type: 'authorization_code',
      code,
      state,
      client_id: (opts.oauth || oauth).clientId,
      redirect_uri: (opts.oauth || oauth).redirectUri,
      code_verifier: verifier,
    },
    { ...opts, oauth: opts.oauth || oauth },
  );
}

// Refresh an account's tokens. Returns the new {accessToken, refreshToken, expiresAt}.
export function refresh({ refreshToken, oauth = OAUTH }, opts = {}) {
  return postToken(
    {
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: (opts.oauth || oauth).clientId,
    },
    { ...opts, oauth: opts.oauth || oauth },
  );
}
