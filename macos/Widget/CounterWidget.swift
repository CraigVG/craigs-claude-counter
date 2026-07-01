import WidgetKit
import SwiftUI

// MARK: - Timeline

struct CCCEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountDTO]
    let offline: Bool
}

struct CCCProvider: TimelineProvider {
    func placeholder(in context: Context) -> CCCEntry {
        CCCEntry(date: Date(), accounts: CCCSample.accounts, offline: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (CCCEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await fetchEntry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CCCEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
    private func fetchEntry() async -> CCCEntry {
        let base = ProcessInfo.processInfo.environment["CCC_BASE_URL"] ?? "http://127.0.0.1:4319"
        guard let url = URL(string: base + "/api/usage"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            return CCCEntry(date: Date(), accounts: [], offline: true)
        }
        return CCCEntry(date: Date(), accounts: snap.accounts.sorted { $0.sortKey > $1.sortKey }, offline: false)
    }
}

// MARK: - Headline (most-constrained)

struct Headline {
    let label: String, pct: Double, kind: String, sev: Severity, resetsAt: String?
}

func mostConstrained(_ accounts: [AccountDTO]) -> Headline? {
    var best: Headline?
    for a in accounts where a.usage != nil {
        for (k, w) in [("session", a.usage?.session), ("weekly", a.usage?.weekly)] {
            if let p = w?.pct, best == nil || p > best!.pct {
                best = Headline(label: a.name, pct: p, kind: k, sev: Severity.of(p), resetsAt: w?.resetsAt)
            }
        }
    }
    return best
}

func attentionCount(_ accounts: [AccountDTO]) -> Int {
    accounts.filter { ($0.usage != nil && $0.worstPct >= Theme.critPct) || $0.isRelogin }.count
}

// MARK: - Views

struct CCCWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CCCEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  small
            case .systemLarge:  large
            default:            medium
            }
        }
        .containerBackground(for: .widget) { Theme.bg }
    }

    // small: the single most-pressing number
    private var small: some View {
        let h = mostConstrained(entry.accounts)
        let attn = attentionCount(entry.accounts)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("CCC").font(Theme.mono(11, .semibold)).foregroundColor(Theme.ink3).tracking(1)
                Spacer()
            }
            Spacer()
            if entry.offline {
                Text("engine\noffline").font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink3)
            } else if let h = h {
                Text("\(Int(h.pct))%").font(Theme.mono(38, .semibold)).foregroundColor(h.sev.color)
                Text(h.kind).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
                Text(h.label).font(Theme.ui(12, .medium)).foregroundColor(Theme.ink2).lineLimit(1).truncationMode(.middle)
            } else {
                Text("All clear").font(Theme.ui(17, .semibold)).foregroundColor(Theme.ok)
            }
            Spacer()
            Text(attn > 0 ? "\(attn) need attention" : "\(entry.accounts.count) healthy")
                .font(Theme.mono(10, .regular)).foregroundColor(Theme.ink3)
        }
        .padding(4)
    }

    private var medium: some View { board(maxRows: 3) }
    private var large: some View { board(maxRows: 6) }

    private func board(maxRows: Int) -> some View {
        let h = mostConstrained(entry.accounts)
        let attn = attentionCount(entry.accounts)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Craig's Claude Counter").font(Theme.ui(13, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Text(attn > 0 ? "\(attn) need attention" : "all healthy")
                    .font(Theme.mono(10.5, .regular)).foregroundColor(attn > 0 ? Theme.alarm : Theme.ink3)
            }
            if entry.offline {
                Spacer(); Text("Can't reach the local engine.").font(Theme.ui(12)).foregroundColor(Theme.ink3); Spacer()
            } else if entry.accounts.isEmpty {
                Spacer(); Text("No accounts yet.").font(Theme.ui(12)).foregroundColor(Theme.ink3); Spacer()
            } else {
                if let h = h {
                    Text("\(h.label) · \(Int(h.pct))% \(h.kind)")
                        .font(Theme.mono(10.5, .regular)).foregroundColor(h.sev == .normal ? Theme.ink3 : h.sev.color)
                        .lineLimit(1)
                }
                ForEach(entry.accounts.prefix(maxRows)) { a in
                    WRow(a: a)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }
}

struct WRow: View {
    let a: AccountDTO
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(tickColor).frame(width: 3, height: 22)
            Text(a.name).font(Theme.ui(12, .medium)).foregroundColor(Theme.ink).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            metric(a.usage?.session)
            metric(a.usage?.weekly)
        }
    }
    private func metric(_ w: WindowDTO?) -> some View {
        let sev = Severity.of(w?.pct)
        return Text(w?.pct.map { "\(Int($0))%" } ?? "—")
            .font(Theme.mono(12.5, .semibold)).foregroundColor(sev == .normal ? Theme.ink2 : sev.color)
            .frame(width: 44, alignment: .trailing)
    }
    private var tickColor: Color {
        if a.isRelogin || (a.usage != nil && a.worstPct >= Theme.critPct) { return Theme.alarm }
        if a.usage != nil && a.worstPct >= Theme.warnPct { return Theme.warn }
        return Theme.hair
    }
}

// MARK: - Widget

struct CounterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CraigsClaudeCounterWidget", provider: CCCProvider()) { entry in
            CCCWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Counter")
        .description("Your Claude usage limits across accounts, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CounterWidgetBundle: WidgetBundle {
    var body: some Widget { CounterWidget() }
}

// MARK: - Sample (placeholder/preview)

enum CCCSample {
    static func win(_ p: Double, _ mins: Double) -> WindowDTO {
        WindowDTO(pct: p, resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(mins * 60)), severity: nil, active: nil)
    }
    static func mdl(_ name: String, _ p: Double, _ mins: Double) -> ModelLimitDTO {
        ModelLimitDTO(name: name, pct: p, resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(mins * 60)), severity: nil, active: nil)
    }
    static var accounts: [AccountDTO] {
        [
            AccountDTO(id: "s1", label: "ops@example.com", tier: "Max 20x",
                       usage: UsageDTO(session: win(100, 52), weekly: win(61, 3300), weeklyModels: [mdl("Fable", 22, 3300)], overage: nil),
                       error: nil, message: nil, stale: nil, status: nil),
            AccountDTO(id: "s2", label: "team@acme.dev", tier: "Max 5x",
                       usage: UsageDTO(session: win(78, 120), weekly: win(44, 5400), weeklyModels: nil, overage: nil),
                       error: nil, message: nil, stale: nil, status: nil),
            AccountDTO(id: "s3", label: "you@example.com", tier: "Max 20x",
                       usage: UsageDTO(session: win(22, 170), weekly: win(38, 3180), weeklyModels: nil, overage: nil),
                       error: nil, message: nil, stale: nil, status: nil),
        ]
    }
}
