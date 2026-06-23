# Craig's Claude Counter

**One calm, glanceable view of your Claude Code usage limits across every account you have.**

If you run more than one Claude subscription (or just want to know how close you are to your 5‑hour and weekly limits before you hit the wall), this watches all of them at once and tells you the one thing that matters: *is anything about to run out, and when does it reset?*

![Craig's Claude Counter — a clean status board of Claude usage across accounts](docs/screenshot.png)

It's deliberately quiet. The board stays neutral when everything's fine; color only appears to escalate, so the account that's actually at its limit is the only red thing on screen.

---

## Why

Claude Code shows *your current account's* usage with `/usage`. But if you have several accounts, there's no single place that shows all of them — and nothing that proactively tells you "the Sam's account is maxed for the next hour." This does.

## What it shows, per account

- **Session (5h)** and **Weekly** utilization, as percentages with live reset countdowns
- **Per‑model weekly sub‑limits** (Opus / Sonnet) when active
- **Overage** spend ($ used of your monthly cap), when extra usage is enabled
- Plan tier (Max 20×, Max 5×, Pro), auto‑detected
- A top summary: how many accounts need attention, and the single most‑pressing fact
- Sorted with the most‑constrained account pinned to the top

## How it works

It reads the same endpoint the `claude` CLI's `/usage` command uses
(`GET https://api.anthropic.com/api/oauth/usage`) with each account's OAuth token.
You sign into each account **once** (the standard Claude Code OAuth flow); after that
the tokens are refreshed automatically and the accounts **stay logged in** — the same
mechanism that keeps the `claude` CLI logged in for months.

A few things it does carefully:

- **Tokens live only in the macOS Keychain.** Never written to disk in plaintext, never logged, never committed.
- **Single‑flight token refresh.** A rotating refresh token is never spent twice (which would trip Anthropic's reuse‑detection and revoke the account). Concurrent refreshes share one request.
- **Background keep‑alive.** The server proactively refreshes tokens before they lapse, so accounts stay logged in even if you never open the page.
- **Tailnet‑private, never public.** It binds to your [Tailscale](https://tailscale.com) IP (so you can check it from your phone) and `127.0.0.1` — never the public internet.
- **Zero dependencies.** Pure Node built‑ins. Nothing to `npm install`.

> Not affiliated with Anthropic. It only ever reads *your own* usage, using the public Claude Code OAuth client (the same one the official CLI and other community tools use).

## Quick start (web app)

Requirements: **Node 18+** and **macOS** (it uses the Keychain).

```bash
git clone https://github.com/CraigVG/craigs-claude-counter.git
cd craigs-claude-counter
npm start
```

It prints two URLs — your Tailscale IP (reachable from your other devices) and
`http://127.0.0.1:4319` locally. Open it, then:

1. Click **+ Add account**.
2. A login tab opens. Sign into the account you want to track and approve.
   - To add a *different* account, switch accounts on claude.ai (or use a private window) first.
3. Copy the code Claude shows you and paste it back in.
4. Repeat for each account. They stay logged in afterward.

### Keep it always running

Install it as a background service that starts at login and restarts if it ever dies:

```bash
./scripts/install-service.sh      # macOS LaunchAgent
```

Remove it later with `./scripts/uninstall-service.sh`.

### See it from your phone / other computers

If you use Tailscale, the URL it prints (`http://<your-mac>.<tailnet>.ts.net:4319`)
works from any device on your tailnet. For HTTPS + a portless URL:

```bash
tailscale serve --bg 4319
```

### Just want to look first?

Open `http://127.0.0.1:4319/?demo=1` for a preview with fake data — no sign‑in required.

## macOS app + desktop widget

There's a **native macOS app** (a window you keep on your desktop, same Status
Board, responsive down to a narrow side panel) and a **WidgetKit desktop widget**
(small / medium / large) so you can glance at your limits without a browser tab.
Both render natively in SwiftUI and read the same local engine — keep `npm start`
(or the LaunchAgent) running and they show live data.

A signed, notarized download + Homebrew cask are on the way. For now, build it:

```bash
cd macos
cp Signing.xcconfig.example Signing.xcconfig   # set your Apple Developer Team ID
xcodegen generate                              # brew install xcodegen
xcodebuild -scheme CraigsClaudeCounter -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Debug/CraigsClaudeCounter.app /Applications/
open /Applications/CraigsClaudeCounter.app     # launch once to register the widget
```

Then add the widget: right-click the desktop → **Edit Widgets** → search **Claude Counter**.

## Security

- Tokens are stored **only** in the macOS Keychain (service `claude-usage-dashboard`); never on disk in plaintext, never logged.
- Binds to your Tailscale IP and `127.0.0.1` — never `0.0.0.0`/the public internet. Don't put it behind a public URL: the stored refresh tokens grant access to each subscription.
- Only `api.anthropic.com`, `claude.ai`, and `platform.claude.com` are ever contacted.

## Configuration

Optional environment variables (sensible defaults; nothing required):

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_USAGE_PORT` | `4319` | Port to listen on |
| `CLAUDE_USAGE_BIND` | auto (Tailscale IP, else `127.0.0.1`) | Bind host |
| `CLAUDE_USAGE_POLL_MS` | `30000` | Browser poll interval |
| `CLAUDE_USAGE_CACHE_MS` | `60000` | Min interval between upstream fetches per account |
| `CLAUDE_USAGE_WARN` / `_CRIT` | `70` / `90` | Severity thresholds (%) |
| `CLAUDE_USAGE_KEYCHAIN` | `claude-usage-dashboard` | Keychain service name |

## Development

```bash
npm test     # node --test — unit + integration tests, zero deps
```

Layout:

```
src/         Node server + core logic (config, credstore, oauth, usage, server)
web/         the browser dashboard (single self-contained index.html)
bin/         claude-usage — a CLI table from the running server
test/        node:test suites
macos/       native SwiftUI app + WidgetKit desktop widget
docs/        screenshots + design notes
```

## License

[MIT](LICENSE) © Craig Vander Galien
