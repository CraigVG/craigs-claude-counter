import SwiftUI

/// Row density. `auto` picks compact whenever the comfortable board would not
/// fit the window height, so many accounts never force a scroll by default.
enum Density: String, CaseIterable {
    case auto, comfortable, compact
    static let storageKey = "density"
}

/// Column widths + spacing for the board (account column is flexible).
/// Compact mode lays each cell out on one line, so metric columns get wider
/// while rows get much shorter (~35pt vs ~91pt).
struct BoardLayout {
    let compact: Bool
    var tick: CGFloat { 4 }
    var plan: CGFloat { 84 }
    var metric: CGFloat { compact ? 200 : 150 }
    var model: CGFloat { compact ? 104 : 96 }
    var over: CGFloat { compact ? 170 : 150 }
    var action: CGFloat { compact ? 64 : 78 }
    var gap: CGFloat { compact ? 12 : 18 }
    var rowVPad: CGFloat { compact ? 6 : 15 }
    var tickHeight: CGFloat { compact ? 22 : 46 }
    var headVPad: CGFloat { compact ? 8 : 12 }

    /// Estimated total height of the comfortable layout (chrome + rows) used to
    /// decide `auto` density. Chrome (244) = outer padding, header, summary
    /// strip, board header, legend and the spacing between them. A comfortable
    /// row is the stacked metric cell (~60pt) + 30pt padding + divider.
    static func comfortableHeight(rows: Int, fleet: Bool = false) -> CGFloat { 244 + (fleet ? 132 : 0) + CGFloat(rows) * 91 }
}

struct DashboardView: View {
    @ObservedObject var model: CounterModel
    @AppStorage(Density.storageKey) private var densityRaw = Density.auto.rawValue

    private var accounts: [AccountDTO] {
        (model.snapshot?.accounts ?? []).sorted { $0.sortKey < $1.sortKey }   // most available on top
    }

    private var density: Density { Density(rawValue: densityRaw) ?? .auto }

    /// The fleet picture, when the engine could count at least one account.
    private var fleet: FleetDTO? {
        guard let f = model.snapshot?.fleet, f.usedPct != nil else { return nil }
        return f
    }

    private func isCompact(height: CGFloat) -> Bool {
        switch density {
        case .compact: return true
        case .comfortable: return false
        case .auto: return BoardLayout.comfortableHeight(rows: accounts.count, fleet: fleet != nil) > height
        }
    }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 760
            let compact = !narrow && isCompact(height: geo.size.height)
            let layout = BoardLayout(compact: compact)
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: narrow ? 13 : (compact ? 12 : 18)) {
                    header(narrow: narrow, compact: compact)
                    if accounts.isEmpty {
                        summaryless
                        Spacer(minLength: 0)
                    } else {
                        if let f = fleet {
                            FleetBar(fleet: f, now: model.tick, compact: compact, narrow: narrow)
                        }
                        SummaryStrip(accounts: accounts, now: model.tick, compact: compact)
                        ScrollView(showsIndicators: false) {
                            if narrow { cardsList } else { board(layout) }
                        }
                        legend(narrow: narrow)
                    }
                }
                .padding(narrow ? 16 : (compact ? 16 : 24))
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .add:
                AddAccountSheet(model: model)
            case .relogin(let id, let label):
                AddAccountSheet(model: model, replaceId: id, replaceLabel: label)
            case .remove(let a):
                RemoveSheet(model: model, account: a)
            }
        }
    }

    // MARK: header
    private func header(narrow: Bool, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: narrow ? 8 : 12) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 3))
            Text(narrow ? "Claude Counter" : "Craig's Claude Counter")
                .font(Theme.ui(narrow ? 15 : 17, .semibold)).foregroundColor(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            if !narrow && !accounts.isEmpty {
                Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(Theme.mono(12, .regular)).foregroundColor(Theme.ink3)
            }
            Spacer(minLength: 8)
            if !narrow { freshness }
            if !narrow && !accounts.isEmpty {
                Button { densityRaw = (compact ? Density.comfortable : Density.compact).rawValue } label: {
                    Text("\u{2261}  Compact")
                }
                .buttonStyle(SoftButton(active: compact))
                .help(compact ? "Switch to comfortable rows" : "Switch to compact single-line rows")
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            Button { Task { await model.load() } } label: { Text(narrow ? "\u{21bb}" : "\u{21bb}  Refresh") }
                .buttonStyle(SoftButton())
            Button { model.openAddAccount() } label: { Text(narrow ? "+" : "+  Add account") }
                .buttonStyle(SoftButton())
        }
    }

    private var cardsList: some View {
        VStack(spacing: 12) {
            ForEach(accounts) { a in
                AccountCard(a: a, now: model.tick,
                            onRelogin: { model.openReLogin(a) },
                            onRemove: { model.openRemove(a) })
            }
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
    private func board(_ layout: BoardLayout) -> some View {
        VStack(spacing: 0) {
            boardHeader(layout)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { _, a in
                AccountRowView(a: a, now: model.tick, layout: layout,
                               onRelogin: { model.openReLogin(a) },
                               onRemove: { model.openRemove(a) })
                Divider().background(Theme.hairSoft)
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair, lineWidth: 1))
    }

    private func boardHeader(_ layout: BoardLayout) -> some View {
        HStack(spacing: layout.gap) {
            Color.clear.frame(width: layout.tick)
            headCell("ACCOUNT", align: .leading).frame(maxWidth: .infinity, alignment: .leading)
            headCell("PLAN").frame(width: layout.plan, alignment: .leading)
            headCell("SESSION · 5H").frame(width: layout.metric, alignment: .leading)
            headCell("WEEKLY").frame(width: layout.metric, alignment: .leading)
            headCell("MODEL WK").frame(width: layout.model, alignment: .leading)
            headCell("OVERAGE").frame(width: layout.over, alignment: .leading)
            Color.clear.frame(width: layout.action)
        }
        .padding(.horizontal, 16).padding(.vertical, layout.headVPad)
        .overlay(Rectangle().fill(Theme.hair).frame(height: 1), alignment: .bottom)
    }

    private func headCell(_ s: String, align: Alignment = .leading) -> some View {
        Text(s).font(Theme.mono(10.5, .medium)).foregroundColor(Theme.ink3).tracking(1.0)
    }

    private func legend(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 12 : 18) {
            if narrow {
                freshness
                Spacer()
                legendKey(Theme.warn, "70%+")
                legendKey(Theme.alarm, "90%+")
            } else {
                legendKey(Theme.calm, "fine <70%")
                legendKey(Theme.warn, "warning 70–89%")
                legendKey(Theme.alarm, "at limit ≥90%")
                Spacer()
                Text("sorted by headroom · most available on top")
            }
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
    var layout = BoardLayout(compact: false)
    var onRelogin: () -> Void
    var onRemove: () -> Void
    @State private var hover = false

    private var rowSeverity: Severity {
        if a.isRelogin { return .alarm }
        return Severity.of(a.usage == nil ? nil : a.worstPct)
    }

    var body: some View {
        let compact = layout.compact
        HStack(spacing: layout.gap) {
            Rectangle().fill(tickColor).frame(width: layout.tick, height: layout.tickHeight)
            account.frame(maxWidth: .infinity, alignment: .leading)
            plan.frame(width: layout.plan, alignment: .leading)
            MetricCell(w: a.usage?.session, kind: .session, dim: a.isRelogin, now: now, compact: compact).frame(width: layout.metric, alignment: .leading)
            MetricCell(w: a.usage?.weekly, kind: .weekly, dim: a.isRelogin, now: now, compact: compact).frame(width: layout.metric, alignment: .leading)
            ModelCell(usage: a.usage, compact: compact).frame(width: layout.model, alignment: .leading)
            OverageCell(usage: a.usage, compact: compact).frame(width: layout.over, alignment: .leading)
            actions.frame(width: layout.action, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, layout.rowVPad)
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

    /// Name stacked over its status tag; in compact mode the tag sits inline.
    @ViewBuilder private var account: some View {
        let name = Text(a.name).font(Theme.ui(layout.compact ? 13 : 14, .medium)).foregroundColor(Theme.ink)
            .lineLimit(1).truncationMode(.tail)
        if layout.compact {
            HStack(spacing: 8) { name; statusTag }
        } else {
            VStack(alignment: .leading, spacing: 4) { name; statusTag }
        }
    }

    @ViewBuilder private var statusTag: some View {
        if a.isRelogin {
            tag("NEEDS RE-LOGIN", color: Theme.alarm)
        } else if a.stale == true {
            tag("CACHED", color: Theme.warn)
        } else if a.isErrored {
            tag("UNAVAILABLE", color: Theme.ink3)
        }
    }

    private func tag(_ s: String, color: Color) -> some View {
        Text(s).font(Theme.mono(9.5, .medium)).foregroundColor(color).tracking(0.5)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var plan: some View {
        Text(a.tier ?? "—")
            .font(Theme.mono(layout.compact ? 11 : 11.5, .regular)).foregroundColor(a.tier == nil ? Theme.ink4 : Theme.ink2)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 8).padding(.vertical, layout.compact ? 2 : 3)
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
    var compact: Bool = false

    private var pct: Double? { w?.pct }
    private var sev: Severity { Severity.of(pct) }

    private var resetLabel: String {
        guard let pct = pct else { return kind == .session ? "no active session" : "no data" }
        return pct > 0 ? TimeFmt.resetText(w?.resetsAt, now: now) : (kind == .session ? "idle" : "at rest")
    }
    private var resetColor: Color {
        guard let pct = pct else { return Theme.ink4 }
        return sev == .alarm ? Color(hex: 0xcf9a9c) : (pct > 0 ? Theme.ink3 : Theme.ink4)
    }

    /// "23%" with the sign smaller and dimmer; "—" when there is no window.
    private func pctText(_ size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if let pct = pct {
                Text("\(Int(pct))").font(Theme.mono(size, .semibold)).foregroundColor(sev.color)
                Text("%").font(Theme.mono(size * 0.6, .medium)).foregroundColor(sev == .idle ? Theme.ink4 : Theme.ink3)
            } else {
                Text("—").font(Theme.mono(size, .semibold)).foregroundColor(Theme.ink4)
            }
        }
    }

    var body: some View {
        Group {
            if compact {
                // one line: 23% ▬▬▬▬ resets in 2h 11m
                HStack(alignment: .center, spacing: 6) {
                    pctText(15).frame(width: 40, alignment: .leading)
                    Meter(pct: pct ?? 2, sev: pct == nil ? .idle : sev, maxW: 42).frame(width: 42)
                    Text(resetLabel).font(Theme.mono(10.5, .regular)).foregroundColor(resetColor)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    pctText(23)
                    Meter(pct: pct ?? 2, sev: pct == nil ? .idle : sev)
                    Text(resetLabel).font(Theme.mono(11, .regular)).foregroundColor(resetColor)
                }
            }
        }
        .opacity(dim ? 0.4 : 1)
    }
}

struct Meter: View {
    let pct: Double
    let sev: Severity
    var maxW: CGFloat = 140
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x20242c))
                Capsule().fill(sev.meterColor)
                    .frame(width: max(3, geo.size.width * min(100, max(2, pct)) / 100))
            }
        }
        .frame(maxWidth: maxW, alignment: .leading)
        .frame(height: 4)
    }
}

struct ModelCell: View {
    let usage: UsageDTO?
    var compact: Bool = false

    private func valueColor(_ pct: Double) -> Color {
        let c = Severity.of(pct).color
        return c == Theme.ink ? Theme.ink2 : c
    }

    var body: some View {
        let rows = models()
        if rows.isEmpty {
            Text("—").font(Theme.mono(12, .regular)).foregroundColor(Theme.ink4)
        } else if compact {
            // "FABLE 48%  OPUS 12%" on one line; shrinks a little if several models report.
            HStack(spacing: 10) {
                ForEach(rows, id: \.0) { (name, pct) in
                    HStack(spacing: 4) {
                        Text(name).font(Theme.mono(9.5, .regular)).foregroundColor(Theme.ink3)
                        Text("\(Int(pct))%").font(Theme.mono(12, .medium)).foregroundColor(valueColor(pct))
                    }
                }
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows, id: \.0) { (name, pct) in
                    HStack(spacing: 9) {
                        Text(name).font(Theme.mono(10, .regular)).foregroundColor(Theme.ink3).frame(width: 44, alignment: .leading)
                        Text("\(Int(pct))%").font(Theme.mono(13, .medium)).foregroundColor(valueColor(pct))
                    }
                }
            }
        }
    }
    private func models() -> [(String, Double)] {
        var out: [(String, Double)] = []
        for m in usage?.weeklyModels ?? [] {
            if let p = m.pct { out.append((m.name.uppercased(), p)) }
        }
        return out
    }
}

struct OverageCell: View {
    let usage: UsageDTO?
    var compact: Bool = false
    var body: some View {
        if let o = usage?.overage, o.enabled == true {
            let size: CGFloat = compact ? 12 : 13
            let amount = HStack(spacing: 4) {
                Text(usd(o.usedUsd)).font(Theme.mono(size, .semibold)).foregroundColor(Theme.ink)
                Text("of \(usd(o.limitUsd, fraction: false))").font(Theme.mono(size, .regular)).foregroundColor(Theme.ink3)
            }.lineLimit(1).minimumScaleFactor(0.8)
            if compact {
                HStack(spacing: 8) {
                    amount
                    Meter(pct: o.pct ?? 0, sev: Severity.of(o.pct), maxW: 48).frame(width: 48)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    amount
                    Meter(pct: o.pct ?? 0, sev: Severity.of(o.pct))
                }
            }
        } else {
            Text("no overage").font(Theme.mono(compact ? 11 : 11.5, .regular)).foregroundColor(Theme.ink4)
        }
    }
}

// MARK: - Fleet bar

/// One capacity-weighted bar for every account: used capacity split into what
/// is locked until a weekly reset (solid) and what comes back within ~5h
/// (hatched), the rest of the track being free now. Mirrors the web block.
struct FleetBar: View {
    let fleet: FleetDTO
    let now: Date
    var compact: Bool = false
    var narrow: Bool = false

    private var fill: Color { fleet.fillColor }
    private var numColor: Color { fleet.tone == .normal ? Theme.ink : fill }
    private var pct1: (Double?) -> String { { v in v.map { String(format: "%.1f", $0) } ?? "—" } }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            head
            bar.frame(height: compact ? 8 : 12)
            if !narrow { legend }
            if !fleet.events.isEmpty { relief }
        }
        .padding(.horizontal, narrow ? 14 : (compact ? 16 : 20)).padding(.vertical, narrow ? 12 : (compact ? 10 : 15))
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair, lineWidth: 1))
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: narrow ? 10 : 14) {
            if !narrow {
                Text("FLEET CAPACITY").font(Theme.mono(10.5, .medium)).foregroundColor(Theme.ink3).tracking(1.2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(pct1(fleet.usedPct)).font(Theme.mono(compact ? 18 : 24, .semibold)).foregroundColor(numColor)
                Text("%").font(Theme.mono(compact ? 11 : 13, .medium)).foregroundColor(Theme.ink3)
                Text(" used").font(Theme.ui(13, .medium)).foregroundColor(Theme.ink2)
            }
            HStack(spacing: 4) {
                Text("\(pct1(fleet.freePct))%").font(Theme.mono(12.5, .semibold)).foregroundColor(Theme.ink)
                Text("free now").font(Theme.mono(12.5, .regular)).foregroundColor(Theme.ink2)
            }
            Spacer(minLength: 8)
            if !narrow, let r = fleet.pace.ratio {
                let hot = r >= 1.15
                let dry = fleet.pace.exhausting.count
                HStack(spacing: 4) {
                    Text("weekly burn").foregroundColor(Theme.ink3)
                    Text(String(format: "%.1f×", r)).foregroundColor(hot ? Theme.warn : Theme.ink2).fontWeight(.semibold)
                    Text("pace").foregroundColor(Theme.ink3)
                    if dry > 0 {
                        Text("·").foregroundColor(Theme.ink4)
                        Text("\(dry)").foregroundColor(hot ? Theme.warn : Theme.ink2).fontWeight(.semibold)
                        Text("of \(fleet.pace.accounts) run dry before reset").foregroundColor(Theme.ink3)
                    }
                }
                .font(Theme.mono(11.5, .regular)).lineLimit(1).minimumScaleFactor(0.8)
                .help("Weekly usage divided by the fraction of each weekly window already elapsed, weighted by plan")
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let locked = w * min(100, max(0, fleet.lockedPct ?? 0)) / 100
            let soon = w * min(100, max(0, fleet.backSoonPct ?? 0)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x20242c))
                HStack(spacing: 0) {
                    Rectangle().fill(fill).frame(width: locked)
                    Stripes(spacing: 7, width: 3).fill(fill)
                        .background(fill.opacity(fleet.tone == .normal ? 0 : 0.18))
                        .frame(width: soon)
                }
                .clipShape(Capsule())
                if let p = fleet.onPacePct {
                    Rectangle().fill(Theme.ink.opacity(0.55)).frame(width: 2)
                        .padding(.vertical, -2)
                        .offset(x: max(0, min(w - 2, w * p / 100 - 1)))
                        .help("on-pace usage: \(Int(p.rounded()))%")
                }
            }
        }
        .help(fleetTitle)
    }

    private var fleetTitle: String {
        "Weighted by weekly capacity: Max 20x = 2× the 5x class (Max 5x, Team 5x), 5x = 3.5× Pro. Session limits act as throttles, not share."
    }

    private var legend: some View {
        HStack(spacing: 16) {
            key(swatch: AnyView(RoundedRectangle(cornerRadius: 2).fill(fill)), "\(pct1(fleet.lockedPct))%", "locked until weekly resets")
            key(swatch: AnyView(RoundedRectangle(cornerRadius: 2).fill(fill.opacity(0.2)).overlay(Stripes(spacing: 4, width: 1.5).fill(fill)).clipShape(RoundedRectangle(cornerRadius: 2))), "\(pct1(fleet.backSoonPct))%", "back within \(fleet.soonHours)h")
            key(swatch: AnyView(RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x20242c))), "\(pct1(fleet.freePct))%", "free now")
            if fleet.onPacePct != nil {
                key(swatch: AnyView(RoundedRectangle(cornerRadius: 1).fill(Theme.ink.opacity(0.55)).frame(width: 2)), nil, "sustainable pace")
            }
            if fleet.accounts.blocked > 0 {
                HStack(spacing: 4) {
                    Text("\(fleet.accounts.blocked)").foregroundColor(Theme.alarm).fontWeight(.semibold)
                    Text("of \(fleet.accounts.counted) blocked").foregroundColor(Theme.ink3)
                }
            }
            if fleet.accounts.unknown > 0 {
                Text("\(fleet.accounts.unknown) not counted (no data)").foregroundColor(Theme.ink3)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.mono(11, .regular)).lineLimit(1).minimumScaleFactor(0.75)
    }

    private func key(swatch: AnyView, _ value: String?, _ label: String) -> some View {
        HStack(spacing: 6) {
            swatch.frame(width: 9, height: 9)
            if let v = value { Text(v).foregroundColor(Theme.ink2).fontWeight(.semibold) }
            Text(label).foregroundColor(Theme.ink3)
        }
    }

    private var relief: some View {
        let shown = Array(fleet.events.prefix(narrow ? 2 : (compact ? 3 : 4)))
        return VStack(alignment: .leading, spacing: 5) {
            Divider().background(Theme.hairSoft)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("NEXT").font(Theme.mono(10.5, .medium)).foregroundColor(Theme.ink4).tracking(1.2)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 4) {
                        Text(e.account).foregroundColor(Theme.ink2)
                        Text(e.kind).foregroundColor(Theme.ink3)
                        Text(TimeFmt.inText(e.at, now: now)).font(Theme.mono(12, .semibold)).foregroundColor(Theme.ink)
                        Text(String(format: "+%.1f%%", e.restoresPct)).font(Theme.mono(12, .medium)).foregroundColor(Theme.ok)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !narrow, let fb = fleet.freshBy {
                    HStack(spacing: 4) {
                        Text("all weekly windows fresh by").foregroundColor(Theme.ink4)
                        Text(TimeFmt.dayClock(fb)).foregroundColor(Theme.ink3).fontWeight(.medium)
                    }
                    .font(Theme.mono(11, .regular)).lineLimit(1)
                }
            }
            .font(Theme.ui(12.5)).minimumScaleFactor(0.8)
        }
    }
}


// MARK: - Summary

struct SummaryStrip: View {
    let accounts: [AccountDTO]
    let now: Date
    var compact: Bool = false

    private struct Info { var tone: Severity; var sig: String; var line: AttributedString; var attn: Int; var total: Int }

    var body: some View {
        let info = compute()
        HStack(spacing: 16) {
            Text(info.sig.uppercased()).font(Theme.mono(compact ? 10 : 11, .semibold)).tracking(1.4)
                .foregroundColor(sigColor(info.tone))
                .padding(.horizontal, 9).padding(.vertical, compact ? 3 : 5)
                .background(sigColor(info.tone).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sigColor(info.tone).opacity(0.5), lineWidth: 1))
            Text(info.line).font(Theme.ui(compact ? 13 : 14)).foregroundColor(Theme.ink2)
                .lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(info.attn > 0 ? "\(info.attn) of \(info.total) need attention" : "all \(info.total) healthy")
                .font(Theme.mono(compact ? 12 : 12.5, .regular)).foregroundColor(Theme.ink3)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, compact ? 16 : 20).padding(.vertical, compact ? 9 : 15)
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
    /// Toggle-style buttons render in the accent color while their mode is on.
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12.5, .medium)).foregroundColor(active ? Theme.accent : Theme.ink2)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(active ? Theme.accent.opacity(0.10) : Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.accent.opacity(0.55) : Theme.hair, lineWidth: 1))
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
