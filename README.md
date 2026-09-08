# Craig's Claude Counter

**One calm, glanceable view of your Claude Code usage limits across every account you have.**

Run more than one Claude subscription — or just want to know how close you are to your 5‑hour and weekly limits before you hit the wall? This watches them all and tells you the one thing that matters: *is anything about to run out, and when does it reset?*

![Craig's Claude Counter — a clean status board of Claude usage across accounts](docs/screenshot.png)

It's deliberately quiet: the board stays neutral until an account nears a limit, so the one that's actually maxed is the only red thing on screen. There are three ways to look at it — a built‑in **web dashboard**, a **native macOS app**, and a **desktop widget** — all reading one small local engine.

> Not affiliated with Anthropic. It only ever reads *your own* usage, via the public Claude Code OAuth client (the same one the official CLI uses). Requires **macOS** (tokens live in the Keychain) and **Node 18+**.

## Get started

### 1. Start the engine (this is all you need)

```bash
git clone https://github.com/CraigVG/craigs-claude-counter.git
cd craigs-claude-counter
npm start          # zero dependencies — pure Node
```

It prints a local URL (`http://127.0.0.1:4319`) plus your Tailscale IP. Open it, click **+ Add account**, sign into each account once (paste back the code Claude shows you). That's it — tokens are stored in your Keychain and stay logged in.

- **Keep it running** at login: `./scripts/install-service.sh` (a macOS LaunchAgent; remove with `./scripts/uninstall-service.sh`).
- **Check from your phone/iPad** over [Tailscale](https://tailscale.com): use the `…ts.net:4319` URL it prints, or `tailscale serve --bg 4319` for HTTPS.
- **Just looking?** `http://127.0.0.1:4319/?demo=1` previews it with fake data — no sign‑in.

### 2. Add the native macOS app + desktop widget (optional)

```bash
brew install --cask CraigVG/tap/craigs-claude-counter
# first time only, if Homebrew asks: brew trust craigvg/tap
```

(Or grab the notarized `.dmg` from [Releases](https://github.com/CraigVG/craigs-claude-counter/releases/latest).) Launch it, then add the widget: right‑click the desktop → **Edit Widgets** → search **Claude Counter** (small / medium / large).

The app and widget are the same Status Board rendered natively in SwiftUI; they read the engine from step 1, so keep it running for live data.

## What it shows, per account

- **Session (5h)** and **Weekly** utilization — percentages with live reset countdowns
- **Per‑model weekly sub‑limits** (Opus / Sonnet) and **overage** spend, when active
- Auto‑detected plan tier (Max 20× / Max 5× / Pro)
- A top summary — how many accounts need attention and the single most‑pressing fact. The board lists the most available account first and the most constrained last
- **Compact mode** — one line per account so many accounts fit without scrolling. Auto‑enabled when the normal rows would overflow the window; pin it either way with the **Compact** button (⌘⇧K in the app). `?demo=many` previews it with 12 fake accounts.

## How it works (and why it's safe)

Reads the same endpoint the `claude` CLI's `/usage` uses (`GET /api/oauth/usage`) with each account's OAuth token.

- **Tokens live only in the macOS Keychain** — never on disk in plaintext, never logged, never committed.
- **Single‑flight refresh** — a rotating refresh token is never spent twice (which would trip Anthropic's reuse‑detection), and a background keep‑alive refreshes tokens before they lapse, so accounts stay logged in for months.
- **Tailnet‑private, never public** — binds to your Tailscale IP and `127.0.0.1`, never `0.0.0.0`. Don't put it behind a public URL: the stored tokens grant access to each subscription.
- Only `api.anthropic.com`, `claude.ai`, and `platform.claude.com` are ever contacted.

## Configuration

All optional (sensible defaults; nothing required):

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_USAGE_PORT` | `4319` | Port to listen on |
| `CLAUDE_USAGE_BIND` | auto (Tailscale IP, else `127.0.0.1`) | Bind host |
| `CLAUDE_USAGE_CACHE_MS` | `60000` | Min interval between upstream fetches per account |
| `CLAUDE_USAGE_WARN` / `_CRIT` | `70` / `90` | Severity thresholds (%) |

## Development

```bash
npm test          # node --test — unit + integration, zero deps
```

```
src/    Node engine (config, credstore, oauth, usage, server)
web/    the built-in browser dashboard (one self-contained index.html)
macos/  native SwiftUI app + WidgetKit widget
bin/    claude-usage — a CLI table from the running engine
```

Build the macOS app from source (needs `xcodegen` and an Apple Developer Team):

```bash
cd macos
cp Signing.xcconfig.example Signing.xcconfig    # set DEVELOPMENT_TEAM
xcodegen generate
xcodebuild -scheme CraigsClaudeCounter -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
```

`scripts/release-macos.sh` builds the signed + notarized release DMG.

## License

[MIT](LICENSE) © Craig Vander Galien
