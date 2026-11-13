# claude-usage-dashboard

Personal tool: a tailnet-private dashboard that aggregates Claude Code **session (5h)** and **weekly** limits across multiple Claude accounts. Standalone repo (not part of drillerdb).

## Architecture (vanilla Node, zero npm deps)

- `src/config.mjs` — config + OAuth/endpoint constants + Tailscale IP detection
- `src/credstore.mjs` — macOS Keychain CRUD (one item per account + an `__index__` item)
- `src/oauth.mjs` — PKCE login + token refresh (Claude Code public OAuth client)
- `src/usage.mjs` — fetch/normalize `GET /api/oauth/usage`; fetch profile for labels
- `src/server.mjs` — `node:http` server + JSON API; `ensureFresh` refresh-on-demand
- `src/fleet.mjs` — fleet bar math (weights, binding window, relief events, pace); `FLEET_MODELS` names the models whose per-model weekly limits count (Opus)
- `src/codex.mjs` — Codex (ChatGPT plan) usage via `codex app-server` JSON-RPC (`account/read`, `account/rateLimits/read`); shaped like an account entry, served as `codex` in `/api/usage` (never in `accounts`, which other tools read as the Claude seats), logged to history, counted in the fleet (`Codex Pro` weight 7 in `src/fleet.mjs`); `macos/App/CodexPanel.swift` / `renderCodex` in the page draw it
- `src/board.mjs` — board order: headroom default + click-to-sort columns; mirrored in `macos/App/BoardSort.swift`
- `src/usage-chart.mjs` — account usage-over-time chart math (ranges, series, gap splitting, time ticks); served as `/usage-chart.mjs` to the page's chart and mirrored in `macos/App/HistorySheet.swift` (Swift Charts)
- `weeklyResets` (src/history.mjs) finds weekly rollovers (resetsAt jumps > 1 h) and the unused share of each ended week; served in `/api/history/fleet` as `resets` and drawn as the fleet view's expired-unused panel and tables
- `macos/App/FleetHistorySheet.swift` — fleet capacity over time (three Swift Charts panels, one hover layer via anchor preferences); data from `GET /api/history/fleet` (`fleetHistory` in `src/history.mjs`, which replays `computeFleet` at every logged poll)
- The LaunchAgent runs with `ProcessType` Interactive; without it launchd throttles the engine (~15x slower history reads)
- `src/history.mjs` — usage history: JSONL day files in `history/`, background poller (`startUsagePoller`), `query`/`summarize`; served at `GET /api/history` and `/api/history/summary`
- `web/index.html` — self-contained dashboard (vanilla JS/CSS)
- `bin/claude-usage` — CLI table from the running server; `claude-usage history --since 7d` for trends

## Key facts

- Usage endpoint: `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`). Returns `limits[]` (kinds `session`/`weekly_all`/`weekly_scoped`), legacy `five_hour`/`seven_day`, `spend`/`extra_usage`.
- OAuth (from Claude Code CLI bundle): client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, authorize `https://claude.ai/oauth/authorize`, token `https://platform.claude.com/v1/oauth/token`, redirect `https://platform.claude.com/oauth/code/callback` (manual code paste, `code#state`), PKCE S256.
- Tokens live ONLY in macOS Keychain (service `claude-usage-dashboard`). Never log or write them to disk.
- Banked limit resets: the usage call is `GET /api/oauth/usage?cedar_ember=1` with a `claude-cli/<ver> (external, cli)` User-Agent (`CLI_USER_AGENT`, override `CLAUDE_USAGE_CLI_UA`). Any other UA gets `cedar_ember.ineligible_reason: "surface"` and no grants. Normalized to `usage.bankedResets` (`bankedResetsFrom`), totalled in `fleet.bankedResets`, logged as `banked` in history. Read-only: claiming is a separate `POST /api/organizations/{org}/reset_rate_limits` the dashboard never calls. `juniper_tide` (a session-reset experiment) only comes back with `?at_wall=1` and is not shown.
- Two kinds of banked reset (2026-11): a grant whose `clears` has `seven_day` resets the week (`kind: 'weekly'`); one that clears only `seven_day_overage_included` resets the per-model weekly limit (Fable's) (`kind: 'model'`), and `gives_back_weekly: true` means it also returns that model's share of the week. `bankedResets` carries `weeklyLeft`, `modelLeft`, `modelName` beside `left` (the sum); clients show "2 resets · 3 Fable".
- `weekly_scoped_shares[]` ties a scoped limit (`limit_index` into `limits[]`) to the week: `allowance_percent_of_weekly` (Fable: 50) and `used_percent_of_weekly`. Normalized onto each `weeklyModels` entry as `weeklyAllowancePct` / `weeklySharePct`. Model usage counts in `weekly_all` as well, so the fleet bar stays on the all-models week.
- Profile endpoint `GET /api/oauth/profile` gives `account.email` + `organization.rate_limit_tier` (→ pretty tier). Personal plans prefer `organization.plan_display_name` ("Ultra", "Max" since the 2026-10-30 rename; `rate_limit_tier` still says `max_20x` / `max_5x`).
- No session limit: verified Ultra accounts get no session window (`five_hour` null, no `session` row in `limits[]`). `normalizeUsage` then returns `session: null`, `sessionLimit: false`; clients show "no 5h limit". `sessionLimit` is `true` when a session window exists, `null` when nothing is known.

- History records hold labels, tiers and percentages only. Never log tokens there.
- The poller runs from the server entry point on `CLAUDE_USAGE_HISTORY_MS` (default 5 min); tests drive `poller.tick()` directly with a temp dir.

## Testing

`npm test` (uses `node:test`). `normalizeUsage` is tested against a real captured payload; server tested with injected stub deps; credstore round-trips a throwaway Keychain service.

## Conventions

- Keep it dependency-free. Side-effecting functions take injectable deps (`fetchImpl`, `credstore`, `oauth`, `usage`) so logic stays unit-testable.
- Never bind to public `0.0.0.0`. Tailnet IP or loopback only.
