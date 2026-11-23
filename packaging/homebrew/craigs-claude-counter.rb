# Homebrew cask for Craig's Claude Counter (macOS app).
#
# Distributed via a personal tap:
#   brew tap CraigVG/tap
#   brew install --cask craigs-claude-counter
#
# After notarizing a release, fill in `version` and `sha256` (the script prints
# the DMG's SHA-256), upload the DMG to the matching GitHub release, and copy
# this file into the tap repo (CraigVG/homebrew-tap) under Casks/.
#
# Note: the app reads usage from the local engine (the Node server in this repo).
# Run it with `npm start` / the LaunchAgent so the app + widget show live data.
cask "craigs-claude-counter" do
  version "1.13.0"
  sha256 "ff514f801ccad6da6f370ad79329c162132cef529cde0d16af94fb4c75f35851"

  url "https://github.com/CraigVG/craigs-claude-counter/releases/download/v#{version}/CraigsClaudeCounter.dmg"
  name "Craig's Claude Counter"
  desc "Dashboard for Claude Code usage limits across multiple accounts"
  homepage "https://github.com/CraigVG/craigs-claude-counter"

  depends_on macos: :sonoma

  app "CraigsClaudeCounter.app", target: "Craig's Claude Counter.app"

  zap trash: [
    "~/Library/LaunchAgents/com.craigvg.craigs-claude-counter.plist",
  ]
end
