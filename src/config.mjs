// Runtime configuration for the Claude Usage Dashboard.
// No secrets live here — account tokens are stored in the macOS Keychain.

import { execFileSync } from 'node:child_process';

// OAuth constants for the Claude Code public client, extracted from the
// Claude Code CLI bundle (2.1.181). These are the same values the official
// `claude` login uses.
export const OAUTH = {
  clientId: '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
  authorizeUrl: 'https://claude.ai/oauth/authorize',
  tokenUrl: 'https://platform.claude.com/v1/oauth/token',
  redirectUri: 'https://platform.claude.com/oauth/code/callback',
  scopes: [
    'user:inference',
    'user:profile',
    'user:sessions:claude_code',
    'user:mcp_servers',
    'user:file_upload',
  ],
};

export const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
export const PROFILE_URL = 'https://api.anthropic.com/api/oauth/profile';
export const ANTHROPIC_BETA = 'oauth-2025-04-20';
export const USER_AGENT = 'craigs-claude-counter/1.0 (+tailnet)';

// Keychain service name; every account is one generic-password under it.
// NOTE: kept as 'claude-usage-dashboard' (the project's original name) so existing
// installs keep their stored tokens across the rename. Override with CLAUDE_USAGE_KEYCHAIN.
export const KEYCHAIN_SERVICE = 'claude-usage-dashboard';

// Refresh an access token when it is within this window of expiring.
export const REFRESH_SKEW_MS = 5 * 60 * 1000;

// Try to find the host's Tailscale IPv4 so the dashboard is reachable from
// other tailnet devices but never the public internet. Falls back to loopback.
export function detectBindHost() {
  const candidates = [
    'tailscale',
    '/usr/local/bin/tailscale',
    '/opt/homebrew/bin/tailscale',
    '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  ];
  for (const bin of candidates) {
    try {
      const out = execFileSync(bin, ['ip', '-4'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 3000,
      });
      const ip = out.split('\n').map((l) => l.trim()).find(Boolean);
      if (ip && /^100\./.test(ip)) return ip; // CGNAT range used by Tailscale
      if (ip) return ip;
    } catch {
      // try next candidate
    }
  }
  return '127.0.0.1';
}

export function loadConfig(env = process.env) {
  const port = Number(env.CLAUDE_USAGE_PORT || 4319);
  const bindHost = env.CLAUDE_USAGE_BIND || detectBindHost();
  return {
    port,
    bindHost,
    pollIntervalMs: Number(env.CLAUDE_USAGE_POLL_MS || 30_000),
    // Server-side cache: upstream usage endpoint is hit at most once per
    // account per this window, regardless of how many browsers poll. Protects
    // against the endpoint's own rate limit (429).
    cacheTtlMs: Number(env.CLAUDE_USAGE_CACHE_MS || 60_000),
    // Circuit breaker: after a 429 from upstream, stop calling it for this
    // account for this long (serving last-known data). Prevents an open tab
    // from sustaining the rate limit with a flood of failed retries.
    rateLimitCooldownMs: Number(env.CLAUDE_USAGE_COOLDOWN_MS || 120_000),
    // Background token keep-alive: the always-on server proactively refreshes any
    // access token expiring within `bgRefreshWithinMs`, every `bgRefreshIntervalMs`,
    // so accounts stay logged in even if the dashboard is never opened.
    bgRefreshIntervalMs: Number(env.CLAUDE_USAGE_BG_INTERVAL_MS || 30 * 60_000),
    bgRefreshWithinMs: Number(env.CLAUDE_USAGE_BG_WITHIN_MS || 60 * 60_000),
    // Severity thresholds (percent utilization) for the UI bars.
    warnPct: Number(env.CLAUDE_USAGE_WARN || 70),
    critPct: Number(env.CLAUDE_USAGE_CRIT || 90),
    keychainService: env.CLAUDE_USAGE_KEYCHAIN || KEYCHAIN_SERVICE,
    oauth: OAUTH,
  };
}
