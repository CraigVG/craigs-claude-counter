# Claude Usage Dashboard

One glanceable, auto-refreshing view of **session (5-hour)** and **weekly** limits across **all of your Claude Code accounts** at once — the thing single-account trackers don't do.

Runs on your Mac, reachable across your Tailscale devices, never public. Account tokens live only in the macOS Keychain. Zero npm dependencies (Node built-ins only).

![one card per account: session bar, weekly bar, per-model sub-limits, overage, live "resets in…" countdowns]

## What it shows, per account

- **Session (5h)** utilization % + reset countdown
- **Weekly (all models)** utilization % + reset countdown
- **Per-model weekly sub-limits** (Opus / Sonnet) when active
- **Overage spend** ($ used of monthly cap) when extra usage is enabled
- Plan badge (Max 20x / Max 5x / Pro), auto-detected from the account
- A top summary: how many accounts and which is most constrained right now

## How it works

It calls the same endpoint the `claude` CLI's `/usage` command uses:
`GET https://api.anthropic.com/api/oauth/usage` with each account's OAuth token.
You log into each account once (standard Claude Code OAuth); the dashboard stores
the tokens in your Keychain and **auto-refreshes** them forever after.

## Setup

Requires Node 18+ and macOS (uses the Keychain). Tailscale optional (for cross-device access).

```bash
cd ~/claude-usage-dashboard
npm start
```

It prints a URL like `http://100.x.y.z:4319` (your tailnet IP) and is also at
`http://127.0.0.1:4319` locally. Open it.

### Add your accounts (one-time each)

1. Click **+ Add account**.
2. A new tab opens to the Claude login. **Log into the account you want to track** and approve.
   - To add a *different* account, log out of claude.ai in that tab first (or use a private window), so you authenticate as the right one.
3. Copy the code Claude shows you and paste it back into the prompt.
4. Repeat for each of your accounts.

That's it — tokens refresh automatically; you never re-login unless you revoke access.

## Run it continuously (optional)

Keep it always running and starting at login:

```bash
mkdir -p ~/claude-usage-dashboard/logs
# Edit the node path in the plist if `which node` differs:
cp launchd/com.craigvg.claude-usage-dashboard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.craigvg.claude-usage-dashboard.plist
```

Stop it: `launchctl unload ~/Library/LaunchAgents/com.craigvg.claude-usage-dashboard.plist`

## Quick terminal glance (optional)

```bash
node bin/claude-usage        # prints a compact per-account table
```

## Cross-device over Tailscale (optional, HTTPS)

By default the server binds to your Tailscale IP, so `http://<mac-tailnet-ip>:4319`
works from your iPhone/iPad on the tailnet. For HTTPS + a stable hostname:

```bash
tailscale serve --bg 4319
# then browse to https://<your-mac>.<tailnet>.ts.net
```

## Configuration

Copy `.env.example` to `.env` to override the port, bind host, poll interval, or
severity thresholds. Defaults: port `4319`, bind = auto-detected Tailscale IP
(else `127.0.0.1`), poll `30s`, warn `70%`, critical `90%`.

## Security

- Tokens are stored **only** in the macOS Keychain (service `claude-usage-dashboard`); never written to disk in plaintext, never logged.
- Binds to your Tailscale IP or `127.0.0.1` — never the public `0.0.0.0`. Don't put this behind a public URL: the stored refresh tokens grant access to each subscription.
- Only `api.anthropic.com`, `claude.ai`, and `platform.claude.com` are contacted.

## Tests

```bash
npm test
```

## Design

See [`docs/superpowers/specs/2026-06-18-claude-usage-dashboard-design.md`](docs/superpowers/specs/2026-06-18-claude-usage-dashboard-design.md).
