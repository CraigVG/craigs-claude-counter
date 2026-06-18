# Claude Usage Dashboard — Design

**Date:** 2026-06-18
**Status:** Approved (build proceeding)

## Problem

Craig has **four separate Claude Code subscriptions** (separate Anthropic accounts). Existing usage trackers each watch a *single* logged-in account and don't aggregate multiple accounts at once. He wants one glanceable view of every account's **session (5-hour)** and **weekly** limits, kept up to date automatically.

## Feasibility (proven)

Each account's limits come from a single read-only endpoint that the Claude Code `/usage` command calls:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <account access token>
anthropic-beta: oauth-2025-04-20
```

Live response (captured 2026-06-18, real account) returns:

- `five_hour.{utilization, resets_at}` — the **session** limit
- `seven_day.{utilization, resets_at}` — the **weekly (all models)** limit
- `seven_day_opus`, `seven_day_sonnet` — per-model weekly sub-limits (null when inactive)
- `extra_usage.{is_enabled, monthly_limit, used_credits, utilization, currency}` — overage credits
- `spend.{used, limit, percent, severity, enabled}` — overage in dollars
- `limits[]` — normalized array, each `{kind, group, percent, severity, resets_at, scope, is_active}`
  with `kind` in `session | weekly_all | weekly_scoped`

So per account we can show: session %, weekly %, per-model weekly sub-limits, reset timestamps, severity, and overage spend.

## Decisions (locked with Craig)

| Decision | Choice |
|---|---|
| Where it runs | **Tailscale-private** — runs on the Mac, binds to the tailnet IP, reachable from his other devices; never public |
| Account seeding | **Guided one-time OAuth login per account**, tokens auto-refreshed thereafter |
| Footprint | **Tiny self-contained app** — one small Node server + one HTML page, zero npm deps |
| Token storage | **macOS Keychain** — no plaintext tokens on disk |

## OAuth facts (extracted from Claude Code CLI bundle 2.1.181)

- client_id: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- authorize: `https://claude.ai/oauth/authorize` (params include `code=true`, PKCE S256)
- redirect_uri: `https://platform.claude.com/oauth/code/callback` (manual code paste; success page `/oauth/code/success`)
- token: `https://platform.claude.com/v1/oauth/token`
- scopes: `user:inference user:profile user:sessions:claude_code user:mcp_servers user:file_upload`
- refresh: `grant_type=refresh_token` against the token endpoint

The manual-code-paste flow: user opens the authorize URL, logs into the target account, approves, and is shown a code of the form `<code>#<state>`; they paste it back, we verify `state`, and exchange `code` + PKCE `code_verifier` for tokens.

## Architecture — 6 small modules, vanilla Node (no npm deps)

Uses only built-ins: `node:http`, global `fetch`, `node:crypto` (PKCE), `node:child_process` (`security` CLI), `node:test` (tests).

| Module | Responsibility | Key exports |
|---|---|---|
| `src/config.mjs` | Runtime config + tailnet IP detection | `loadConfig()`, `detectBindHost()` |
| `src/credstore.mjs` | Keychain CRUD, one item per account + an index item | `listAccounts`, `getAccount`, `putAccount`, `deleteAccount` |
| `src/oauth.mjs` | PKCE, authorize URL, code exchange, refresh | `generatePkce`, `buildAuthorizeUrl`, `parsePastedCode`, `exchangeCode`, `refresh`, `parseTokenResponse` |
| `src/usage.mjs` | Fetch + normalize the usage endpoint | `normalizeUsage`, `fetchUsage` |
| `src/server.mjs` | HTTP server + JSON API; refresh-on-demand; per-account isolation | `createServer(deps)`, `ensureFresh` |
| `web/index.html` | Self-contained dashboard page (vanilla JS/CSS) | — |

### Pure vs side-effecting (testability)

Pure (unit-tested directly): `normalizeUsage`, `generatePkce`, `buildAuthorizeUrl`, `parsePastedCode`, `parseTokenResponse`, body builders. Side-effecting (`fetchUsage`, `exchangeCode`, `refresh`, keychain ops, `createServer`) accept injected dependencies so tests stub network/keychain.

## HTTP API (served locally)

- `GET /` → dashboard HTML
- `GET /api/usage` → `{ generatedAt, accounts: [{ id, label, tier, usage|error, stale }] }` — refreshes any token within 5 min of expiry, fetches all accounts in parallel (`Promise.allSettled`), one failure never blanks the others
- `GET /api/accounts` → `[{ id, label, tier, expiresAt }]`
- `POST /api/login/start` `{label}` → `{ loginId, authorizeUrl }` (PKCE+state held in memory)
- `POST /api/login/finish` `{loginId, pastedCode}` → exchanges + stores account
- `DELETE /api/accounts/:id` → removes account from Keychain

## Data flow

```
browser ──poll 30s──▶ GET /api/usage
                         └─ for each account (parallel):
                              ensureFresh()  ── if <5min to expiry ─▶ oauth.refresh ─▶ credstore.putAccount
                              usage.fetchUsage(token) ─▶ normalizeUsage
                         ◀── { accounts:[…] }
browser renders one card per account + a "most-constrained" summary banner
```

## Error handling

- usage `401` → refresh token, retry once; still 401 → account flagged `needs_relogin` with a re-auth button
- usage `429`/`5xx`/network error → keep last-known value, show `stale` badge + timestamp
- refresh fails (revoked refresh token) → `needs_relogin`
- Each account isolated; a single bad account degrades only its own card

## Security

- Tokens only in macOS Keychain (service `claude-usage-dashboard`); never written to disk in plaintext, never logged
- Binds to the Tailscale IP (auto-detected) or `127.0.0.1`; never public `0.0.0.0`
- Login state held in memory only; no inbound callback server (manual code paste)
- Only `api.anthropic.com`, `claude.ai`, `platform.claude.com` are contacted
- Optional `tailscale serve` documented for HTTPS across the tailnet

## Testing

- `usage.test.mjs` — `normalizeUsage` against the real captured sample → asserts session/weekly %, reset times, per-model sub-limits, overage, severity
- `oauth.test.mjs` — `generatePkce` (S256 correctness), `buildAuthorizeUrl` params, `parsePastedCode`, `parseTokenResponse` (expiresAt math), `refresh` against a mocked token endpoint
- `credstore.test.mjs` — round-trip put/get/list/delete against a throwaway Keychain service, cleaned up after
- `server.test.mjs` — boot `createServer` with stubbed `usage`/`credstore`/`oauth`; assert `/api/usage` aggregate shape, refresh-on-demand, and per-account error isolation

## Run & keepalive

- `node src/server.mjs` (prints the tailnet URL)
- `launchd/com.craigvg.claude-usage-dashboard.plist` — start at login, `KeepAlive`, log to file
- `bin/claude-usage` — optional CLI that prints a 4-account table from `/api/usage`

## Location

Standalone repo `~/claude-usage-dashboard/` — deliberately **not** inside the confidential `drillerdb` knowledge repo. This design doc lives with the project.
