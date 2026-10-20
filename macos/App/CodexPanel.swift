import SwiftUI

/// Codex (ChatGPT plan) usage: its own panel and bar under the fleet bar, one
/// bar per rate-limit window Codex reports (weekly, and a 5-hour window when
/// there is one), plus the credits balance. Click for the same over-time
/// chart as a Claude account. Codex also counts in the fleet bar (engine:
/// src/codex.mjs, weight in src/fleet.mjs). Mirrors renderCodex in web/index.html.
struct CodexPanel: View {
    let entries: [AccountDTO]
    var compact: Bool = false
    var narrow: Bool = false
    var onOpen: (AccountDTO) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(entries) { c in panel(c) }
        }
    }

    private func panel(_ c: AccountDTO) -> some View {
        let wins: [(String, WindowDTO)] = [("WEEKLY", c.usage?.weekly), ("5H", c.usage?.session)]
            .compactMap { k, w in w?.pct == nil ? nil : (k, w!) }
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: narrow ? 8 : 12) {
                Text("CODEX").font(Theme.mono(10.5, .medium)).foregroundColor(Theme.ink3).tracking(1.2)
                Text(c.email ?? c.name).font(Theme.mono(12, .regular)).foregroundColor(Theme.ink2).lineLimit(1).truncationMode(.middle)
                if let t = c.tier {
                    Text(t).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hair, lineWidth: 1))
                }
                Spacer(minLength: 8)
                if let b = c.usage?.credits?.balance {
                    HStack(spacing: 4) {
                        Text(Int(b.rounded()).formatted()).fontWeight(.semibold).foregroundColor(Theme.ink2)
                        Text("credits").foregroundColor(Theme.ink3)
                    }
                    .font(Theme.mono(11.5, .regular))
                }
            }
            if wins.isEmpty {
                Text("no rate-limit windows reported").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            }
            ForEach(wins, id: \.0) { k, w in window(k, w) }
            if c.stale == true, let m = c.message {
                Text(m).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            } else if let r = c.usage?.limitReached {
                Text("limit reached (\(r))").font(Theme.mono(11, .regular)).foregroundColor(Theme.alarm)
            }
        }
        .padding(.horizontal, narrow ? 14 : (compact ? 16 : 20)).padding(.vertical, narrow ? 12 : (compact ? 10 : 13))
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onOpen(c) }
        .help("Click for Codex usage over time. Codex counts in the fleet bar.")
    }

    private func window(_ label: String, _ w: WindowDTO) -> some View {
        let pct = min(100, max(0, w.pct ?? 0))
        let sev = Severity.of(pct)
        let fill: Color = sev == .alarm ? Theme.alarm : sev == .warn ? Theme.warn : Theme.calm
        return HStack(spacing: 12) {
            Text(label).font(Theme.mono(10.5, .regular)).tracking(0.8).foregroundColor(Theme.ink3)
                .frame(width: narrow ? 50 : 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x20242c))
                    Capsule().fill(fill).frame(width: max(4, geo.size.width * pct / 100))
                }
            }
            .frame(height: compact ? 8 : 10)
            HStack(spacing: 4) {
                Text("\(Int(pct.rounded()))%").fontWeight(.semibold).foregroundColor(Theme.ink)
                Text("used").foregroundColor(Theme.ink2)
                if pct > 0, let at = TimeFmt.parse(w.resetsAt) {
                    Text("·").foregroundColor(Theme.ink4)
                    Countdown(target: at) { now in
                        Text(TimeFmt.resetText(w.resetsAt, now: now)).foregroundColor(Theme.ink3)
                    }
                } else if w.resetsAt != nil {
                    Text("· \(TimeFmt.restingText(session: false, resetsAt: w.resetsAt))").foregroundColor(Theme.ink3)
                }
            }
            .font(Theme.mono(12, .regular)).lineLimit(1)
            .frame(minWidth: narrow ? 0 : 230, alignment: .trailing)
        }
    }
}
