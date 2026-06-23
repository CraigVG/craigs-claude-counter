import SwiftUI

// Column widths (account column is flexible)
private enum Col {
    static let tick: CGFloat = 4
    static let plan: CGFloat = 80
    static let metric: CGFloat = 150
    static let model: CGFloat = 96
    static let over: CGFloat = 150
    static let action: CGFloat = 78
    static let gap: CGFloat = 18
}

struct DashboardView: View {
    @ObservedObject var model: CounterModel

    private var accounts: [AccountDTO] {
        (model.snapshot?.accounts ?? []).sorted { $0.sortKey > $1.sortKey }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                header
                if accounts.isEmpty {
                    summaryless
                } else {
                    SummaryStrip(accounts: accounts, now: model.tick)
                    board
                    legend
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 460)
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 3))
            Text("Craig's Claude Counter").font(Theme.ui(17, .semibold)).foregroundColor(Theme.ink)
            if !accounts.isEmpty {
                Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(Theme.mono(12, .regular)).foregroundColor(Theme.ink3)
            }
            Spacer()
            freshness
            Button { Task { await model.load() } } label: { Text("\u{21bb}  Refresh") }
                .buttonStyle(SoftButton())
            Button { model.openAddAccount() } label: { Text("+  Add account") }
                .buttonStyle(SoftButton())
        }
    }

    private var freshness: some View {
        let s = model.loadedAt.map { Int(model.tick.timeIntervalSince($0)) } ?? 0
        let behind = (model.lastError != nil) || s > 90
        let txt: String = model.lastError != nil ? "engine offline"
            : model.loadedAt == nil ? "loading…"
            : s < 2 ? "updated just now"
            : s < 60 ? "updated \(s)s ago" : "updated \(s/60)m \(s%60)s ago"
        return HStack(spacing: 7) {
            Circle().fill(behind ? Theme.warn : Theme.ok).frame(width: 6, height: 6)
            Text(txt).font(Theme.mono(11.5, .regular))
        }
        .foregroundColor(behind ? Theme.warn : Theme.ink3)
        .padding(.trailing, 4)
    }

    // MARK: board
    private var board: some View {
        VStack(spacing: 0) {
            boardHeader
            ForEach(Array(accounts.enumerated()), id: \.element.id) { _, a in
                AccountRowView(a: a, now: model.tick,
                               onRelogin: { model.openReLogin(a) },
                               onRemove: { model.openRemove(a) })
                Divider().background(Theme.hairSoft)
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair, lineWidth: 1))
    }

    private var boardHeader: some View {
        HStack(spacing: Col.gap) {
            Color.clear.frame(width: Col.tick)
            headCell("ACCOUNT", align: .leading).frame(maxWidth: .infinity, alignment: .leading)
            headCell("PLAN").frame(width: Col.plan, alignment: .leading)
            headCell("SESSION · 5H").frame(width: Col.metric, alignment: .leading)
            headCell("WEEKLY").frame(width: Col.metric, alignment: .leading)
            headCell("MODEL WK").frame(width: Col.model, alignment: .leading)
            headCell("OVERAGE").frame(width: Col.over, alignment: .leading)
            Color.clear.frame(width: Col.action)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(Rectangle().fill(Theme.hair).frame(height: 1), alignment: .bottom)
    }

    private func headCell(_ s: String, align: Alignment = .leading) -> some View {
        Text(s).font(Theme.mono(10.5, .medium)).foregroundColor(Theme.ink3).tracking(1.0)
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendKey(Theme.calm, "fine <70%")
            legendKey(Theme.warn, "warning 70–89%")
            legendKey(Theme.alarm, "at limit ≥90%")
            Spacer()
            Text("sorted by constraint · most-constrained on top")
        }
        .font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
        .padding(.top, 2)
    }

    private func legendKey(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(t)
        }
    }

    private var summaryless: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 40)
            Text(model.lastError != nil ? "Can't reach the local engine on 127.0.0.1:4319." : "No accounts yet.")
                .font(Theme.ui(14)).foregroundColor(Theme.ink2)
            Text(model.lastError != nil ? "Start it with: npm start (or ./scripts/install-service.sh)." : "Add a Claude account in the web dashboard to begin.")
                .font(Theme.mono(12, .regular)).foregroundColor(Theme.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

struct AccountRowView: View {
    let a: AccountDTO
    let now: Date
    var onRelogin: () -> Void
    var onRemove: () -> Void
    @State private var hover = false

    private var rowSeverity: Severity {
        if a.isRelogin { return .alarm }
        return Severity.of(a.usage == nil ? nil : a.worstPct)
    }

    var body: some View {
        HStack(spacing: Col.gap) {
            Rectangle().fill(tickColor).frame(width: Col.tick, height: 46)
            account.frame(maxWidth: .infinity, alignment: .leading)
            plan.frame(width: Col.plan, alignment: .leading)
            MetricCell(w: a.usage?.session, kind: .session, dim: a.isRelogin, now: now).frame(width: Col.metric, alignment: .leading)
            MetricCell(w: a.usage?.weekly, kind: .weekly, dim: a.isRelogin, now: now).frame(width: Col.metric, alignment: .leading)
            ModelCell(usage: a.usage).frame(width: Col.model, alignment: .leading)
            OverageCell(usage: a.usage).frame(width: Col.over, alignment: .leading)
            actions.frame(width: Col.action, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(rowBackground)
        .onHover { hover = $0 }
    }

    private var tickColor: Color {
        switch rowSeverity { case .alarm: return Theme.alarm; case .warn: return Theme.warn; default: return .clear }
    }
    private var rowBackground: Color {
        if a.usage != nil && a.worstPct >= Theme.critPct { return Theme.alarmBg }
        if a.isRelogin { return Theme.alarm.opacity(0.05) }
        return hover ? Theme.rowHover : .clear
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a.name).font(Theme.ui(14, .medium)).foregroundColor(a.usage == nil && !a.isErrored ? Theme.ink : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
            if a.isRelogin {
                tag("NEEDS RE-LOGIN", color: Theme.alarm)
            } else if a.stale == true {
                tag("CACHED", color: Theme.warn)
            } else if a.isErrored {
                tag("UNAVAILABLE", color: Theme.ink3)
            }
        }
    }

    private func tag(_ s: String, color: Color) -> some View {
        Text(s).font(Theme.mono(9.5, .medium)).foregroundColor(color).tracking(0.5)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var plan: some View {
        Text(a.tier ?? "—")
            .font(Theme.mono(11.5, .regular)).foregroundColor(a.tier == nil ? Theme.ink4 : Theme.ink2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hair, lineWidth: 1))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if a.isRelogin {
                Button(action: onRelogin) { Text("Re-login").font(Theme.ui(11.5, .medium)) }
                    .buttonStyle(PillButton(color: Theme.alarm))
            }
            if hover || a.isRelogin {
                Button(action: onRemove) { Text("✕").font(Theme.ui(13)) }
                    .buttonStyle(PillButton(color: Theme.ink3, subtle: true))
            }
        }
    }
}

// MARK: - Cells

enum MetricKind { case session, weekly }

struct MetricCell: View {
    let w: WindowDTO?
    let kind: MetricKind
    var dim: Bool = false
    let now: Date

    var body: some View {
        let pct = w?.pct
        let sev = Severity.of(pct)
        VStack(alignment: .leading, spacing: 7) {
            if let pct = pct {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(pct))").font(Theme.mono(23, .semibold)).foregroundColor(sev.color)
                    Text("%").font(Theme.mono(14, .medium)).foregroundColor(sev == .idle ? Theme.ink4 : Theme.ink3)
                }
                Meter(pct: pct, sev: sev)
                Text(pct > 0 ? TimeFmt.resetText(w?.resetsAt, now: now) : (kind == .session ? "idle" : "at rest"))
                    .font(Theme.mono(11, .regular))
                    .foregroundColor(sev == .alarm ? Color(hex: 0xcf9a9c) : (pct > 0 ? Theme.ink3 : Theme.ink4))
            } else {
                Text("—").font(Theme.mono(23, .semibold)).foregroundColor(Theme.ink4)
                Meter(pct: 2, sev: .idle)
                Text(kind == .session ? "no active session" : "no data").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            }
        }
        .opacity(dim ? 0.4 : 1)
    }
}

struct Meter: View {
    let pct: Double
    let sev: Severity
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x20242c))
                Capsule().fill(sev.meterColor)
                    .frame(width: max(3, geo.size.width * min(100, max(2, pct)) / 100))
            }
        }
        .frame(width: 140, height: 4)
    }
}

struct ModelCell: View {
    let usage: UsageDTO?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let rows = models()
            if rows.isEmpty {
                Text("—").font(Theme.mono(12, .regular)).foregroundColor(Theme.ink4)
            } else {
                ForEach(rows, id: \.0) { (name, pct) in
                    HStack(spacing: 9) {
                        Text(name).font(Theme.mono(10, .regular)).foregroundColor(Theme.ink3).frame(width: 44, alignment: .leading)
                        Text("\(Int(pct))%").font(Theme.mono(13, .medium)).foregroundColor(Severity.of(pct).color == Theme.ink ? Theme.ink2 : Severity.of(pct).color)
                    }
                }
            }
        }
    }
    private func models() -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let p = usage?.weeklyOpus?.pct { out.append(("OPUS", p)) }
        if let p = usage?.weeklySonnet?.pct { out.append(("SONNET", p)) }
        return out
    }
}

struct OverageCell: View {
    let usage: UsageDTO?
    var body: some View {
        if let o = usage?.overage, o.enabled == true {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(usd(o.usedUsd)).font(Theme.mono(13, .semibold)).foregroundColor(Theme.ink)
                    Text("of \(usd(o.limitUsd, fraction: false))").font(Theme.mono(13, .regular)).foregroundColor(Theme.ink3)
                }
                Meter(pct: o.pct ?? 0, sev: Severity.of(o.pct))
            }
        } else {
            Text("no overage").font(Theme.mono(11.5, .regular)).foregroundColor(Theme.ink4)
        }
    }
}

// MARK: - Summary

struct SummaryStrip: View {
    let accounts: [AccountDTO]
    let now: Date

    private struct Info { var tone: Severity; var sig: String; var line: AttributedString; var attn: Int; var total: Int }

    var body: some View {
        let info = compute()
        HStack(spacing: 16) {
            Text(info.sig.uppercased()).font(Theme.mono(11, .semibold)).tracking(1.4)
                .foregroundColor(sigColor(info.tone))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(sigColor(info.tone).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sigColor(info.tone).opacity(0.5), lineWidth: 1))
            Text(info.line).font(Theme.ui(14)).foregroundColor(Theme.ink2)
            Spacer()
            Text(info.attn > 0 ? "\(info.attn) of \(info.total) need attention" : "all \(info.total) healthy")
                .font(Theme.mono(12.5, .regular)).foregroundColor(Theme.ink3)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            HStack(spacing: 0) { Rectangle().fill(sigColor(compute().tone)).frame(width: 3); Spacer() }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair, lineWidth: 1))
    }

    private func sigColor(_ tone: Severity) -> Color {
        switch tone { case .alarm: return Theme.alarm; case .warn: return Theme.warn; default: return Theme.ok }
    }

    private func compute() -> Info {
        let live = accounts.filter { $0.usage != nil }
        let relogin = accounts.filter { $0.isRelogin }
        var worst: (pct: Double, label: String, kind: String, resets: String?)? = nil
        for a in live {
            for (k, w) in [("session", a.usage?.session), ("weekly", a.usage?.weekly)] {
                if let p = w?.pct, worst == nil || p > worst!.pct {
                    worst = (p, a.name, k, w?.resetsAt)
                }
            }
        }
        let attn = live.filter { $0.worstPct >= Theme.critPct }.count + relogin.count

        func line(_ s: String) -> AttributedString { (try? AttributedString(markdown: s)) ?? AttributedString(s) }

        if let w = worst, w.pct >= Theme.critPct {
            return Info(tone: .alarm, sig: "At limit",
                        line: line("**\(w.label)** is at **\(Int(w.pct))%** (\(w.kind)) — \(TimeFmt.resetText(w.resets, now: now))"),
                        attn: attn, total: accounts.count)
        } else if !relogin.isEmpty {
            let l = relogin.count == 1 ? "**\(relogin[0].name)** needs you to sign in again"
                                       : "**\(relogin.count) accounts** need you to sign in again"
            return Info(tone: .alarm, sig: "Re-login", line: line(l), attn: attn, total: accounts.count)
        } else if let w = worst, w.pct >= Theme.warnPct {
            return Info(tone: .warn, sig: "Warning",
                        line: line("**\(w.label)** is at **\(Int(w.pct))%** (\(w.kind)) — \(TimeFmt.resetText(w.resets, now: now))"),
                        attn: attn, total: accounts.count)
        } else if let w = worst {
            return Info(tone: .normal, sig: "All clear",
                        line: line("Most used: **\(w.label)** at **\(Int(w.pct))%** — plenty of headroom"),
                        attn: 0, total: accounts.count)
        }
        return Info(tone: .normal, sig: "All clear", line: line("No usage right now"), attn: 0, total: accounts.count)
    }
}

// MARK: - Button styles

struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12.5, .medium)).foregroundColor(Theme.ink2)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PillButton: ButtonStyle {
    var color: Color
    var subtle: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(subtle ? Color.clear : color.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(subtle ? Color.clear : color.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
