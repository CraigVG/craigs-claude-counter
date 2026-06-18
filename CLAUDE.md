# claude-usage-dashboard

Personal tool: a tailnet-private dashboard that aggregates Claude Code **session (5h)** and **weekly** limits across multiple Claude accounts. Standalone repo (not part of drillerdb).

## Architecture (vanilla Node, zero npm deps)

- `src/config.mjs` — config + OAuth/endpoint constants + Tailscale IP detection
- `src/credstore.mjs` — macOS Keychain CRUD (one item per account + an `__index__` item)
- `src/oauth.mjs` — PKCE login + token refresh (Claude Code public OAuth client)
- `src/usage.mjs` — fetch/normalize `GET /api/oauth/usage`; fetch profile for labels
- `src/server.mjs` — `node:http` server + JSON API; `ensureFresh` refresh-on-demand
- `web/index.html` — self-contained dashboard (vanilla JS/CSS)
- `bin/claude-usage` — CLI table from the running server

## Key facts

- Usage endpoint: `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`). Returns `limits[]` (kinds `session`/`weekly_all`/`weekly_scoped`), legacy `five_hour`/`seven_day`, `spend`/`extra_usage`.
- OAuth (from Claude Code CLI bundle): client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, authorize `https://claude.ai/oauth/authorize`, token `https://platform.claude.com/v1/oauth/token`, redirect `https://platform.claude.com/oauth/code/callback` (manual code paste, `code#state`), PKCE S256.
- Tokens live ONLY in macOS Keychain (service `claude-usage-dashboard`). Never log or write them to disk.
- Profile endpoint `GET /api/oauth/profile` gives `account.email` + `organization.rate_limit_tier` (→ pretty tier).

## Testing

`npm test` (uses `node:test`). `normalizeUsage` is tested against a real captured payload; server tested with injected stub deps; credstore round-trips a throwaway Keychain service.

## Conventions

- Keep it dependency-free. Side-effecting functions take injectable deps (`fetchImpl`, `credstore`, `oauth`, `usage`) so logic stays unit-testable.
- Never bind to public `0.0.0.0`. Tailnet IP or loopback only.
