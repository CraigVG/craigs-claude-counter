import SwiftUI
import Charts

/// The fleet bar over time, opened from the fleet bar. Reads
/// GET /api/history/fleet, which replays the fleet math at every logged poll.
/// Three panels on one time axis: capacity (used, split into locked until a
/// weekly reset and back within 5h), accounts blocked, and weekly burn vs
/// pace. Mirrors the web view (web/index.html drawFleetChart).
///
/// Built like HistorySheet for speed: data prepared once per load, each panel
/// an equatable chart, hover in one sibling layer that finds the panels'
/// plot areas through anchor preferences. The sheet does not observe the model.
struct FleetHistorySheet: View {
    let model: CounterModel
    /// The board's accounts when the sheet opened, for "use it or lose it".
    let accounts: [AccountDTO]
    private var accountCount: Int { accounts.count }
    @Environment(\.dismiss) private var dismiss
    @AppStorage("historyRange") private var rangeRaw = HistoryRange.week.rawValue

    @State private var data: FleetData?
    @State private var loading = true
    @State private var failure: String?

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Fleet capacity").font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink)
                if accountCount > 0 {
                    Text("\(accountCount) account\(accountCount == 1 ? "" : "s"), plan-weighted").font(Theme.mono(11.5, .regular)).foregroundColor(Theme.ink3)
                }
                Spacer()
                Button { dismiss() } label: { Text("✕").font(Theme.ui(14)).foregroundColor(Theme.ink3) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Rectangle().fill(Theme.hair).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Range", selection: $rangeRaw) {
                        ForEach(HistoryRange.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    FleetLegend()
                    if let d = data { StatTiles(tiles: d.tiles) }
                    chartArea
                    Text(data?.footnote ?? " ").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
                    ExpiringSoon(items: ExpiringItem.from(accounts))
                    if let d = data { ExpiredTable(data: d) }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 680, idealHeight: 820)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task(id: rangeRaw) { await load() }
    }

    private func load() async {
        loading = true
        failure = nil
        let r = range
        do {
            let resp = try await model.fleetHistory(range: r)
            data = FleetData(resp, range: r)
        } catch {
            failure = "Could not load fleet history (\(error.localizedDescription)). Is the engine running?"
        }
        loading = false
    }

    @ViewBuilder private var chartArea: some View {
        if let f = failure {
            centered(f)
        } else if let d = data, !d.samples.isEmpty {
            FleetPanels(data: d)
        } else if loading {
            centered("Loading…")
        } else {
            centered("No fleet history in this range yet. The engine logs every account every few minutes.")
        }
    }

    private func centered(_ s: String) -> some View {
        Text(s).font(Theme.ui(13)).foregroundColor(Theme.ink3).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).frame(height: 360)
    }
}

// MARK: - Data

struct FleetSample {
    let date: Date
    let used: Double
    let locked: Double
    let soon: Double
    let free: Double
    let blocked: Int
    let total: Int
    let pace: Double?
    let stale: Int
}

struct FleetData {
    let id = UUID()
    let range: HistoryRange
    let samples: [FleetSample]
    let runs: [[FleetSample]]
    let domain: ClosedRange<Date>
    let maxAccounts: Int
    let paceMax: Double
    let tiles: [StatTile]
    let footnote: String
    /// Weekly resets in the range, and the expired-unused bars drawn from them
    /// (one per reset on 24h / 7d, one per local day on 30d / 90d).
    let resets: [FleetReset]
    let bars: [ExpiredBar]
    let barMax: Double
    let perDay: Bool
    let resetCount: Int
    let expiredPct: Double?
    let expiredUnits: Double

    init(_ resp: FleetHistoryResp, range: HistoryRange) {
        self.range = range
        let samples = resp.points.compactMap { p -> FleetSample? in
            guard let d = TimeFmt.parse(p.ts), let used = p.usedPct else { return nil }
            return FleetSample(date: d, used: used, locked: p.lockedPct ?? used, soon: p.backSoonPct ?? 0, free: p.freePct ?? max(0, 100 - used),
                               blocked: p.blocked ?? 0, total: p.total ?? 0, pace: p.paceRatio, stale: p.stale ?? 0)
        }
        self.samples = samples
        var runs: [[FleetSample]] = []
        var run: [FleetSample] = []
        for s in samples {
            if let last = run.last, s.date.timeIntervalSince(last.date) > range.fleetGapSeconds { runs.append(run); run = [] }
            run.append(s)
        }
        if !run.isEmpty { runs.append(run) }
        self.runs = runs

        let until = Date(), want = until.addingTimeInterval(-range.seconds)
        let clipped = samples.first.map { $0.date.timeIntervalSince(want) > range.seconds * 0.1 } ?? false
        domain = (clipped ? samples[0].date : want)...until
        let sm = resp.summary
        maxAccounts = max(1, sm?.maxAccounts ?? samples.map(\.total).max() ?? 1)
        // Right after a weekly reset little of the week has elapsed and the
        // ratio spikes; cap the axis at 4x so 0.5-2x stays readable.
        paceMax = min(4, max(2, ((samples.compactMap(\.pace).max() ?? 0) * 2).rounded(.up) / 2))

        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }
        var tiles = [
            StatTile(label: "Avg used", value: pct(sm?.avgUsedPct), help: "Average plan-weighted fleet usage over the range (the fleet bar's number)"),
            StatTile(label: "Peak used", value: pct(sm?.maxUsedPct), help: "Highest fleet usage in the range"),
            StatTile(label: "Lowest free", value: pct(sm?.minFreePct), help: "The least free capacity the fleet had at any poll"),
            StatTile(label: "Any blocked", value: StatTile.duration((sm?.blockedMs ?? 0) / 1000), help: "Time with at least one account at 100% (session or weekly)"),
            StatTile(label: "Peak blocked", value: sm?.peakBlocked.map { "\($0) of \(sm?.maxAccounts ?? 0)" } ?? "—", help: "Most accounts blocked at the same time"),
            StatTile(label: "Avg burn", value: sm?.avgPaceRatio.map { String(format: "%.1f×", $0) } ?? "—", help: "Weekly usage vs the share of each weekly window elapsed, plan-weighted; 1× is sustainable"),
        ]
        if let ms = sm?.atLimitMs, ms > 0 {
            tiles.insert(StatTile(label: "Fleet at \(Int(Theme.critPct))%+", value: StatTile.duration(ms / 1000), help: "Time with the whole fleet at \(Int(Theme.critPct))% or more used"), at: 3)
        }

        let resets = (resp.resets ?? []).compactMap { r -> FleetReset? in
            guard let d = TimeFmt.parse(r.at) else { return nil }
            return FleetReset(account: r.account, label: r.label ?? r.account, tier: r.tier, date: d, unusedPct: r.unusedPct ?? 0,
                              units: r.units ?? 0, weight: r.weight ?? 0, fleetPct: r.fleetPct, approx: r.approx == true)
        }
        self.resets = resets
        let perDay = range == .month || range == .quarter
        self.perDay = perDay
        var bars: [ExpiredBar] = []
        let cal = Calendar.current
        for e in resets where e.units > 0 && e.fleetPct != nil && domain.contains(e.date) {
            let start = perDay ? cal.startOfDay(for: e.date) : e.date
            if perDay, let i = bars.firstIndex(where: { $0.start == start }) {
                bars[i].pct += e.fleetPct ?? 0
                bars[i].events.append(e)
            } else {
                let end = perDay ? (cal.date(byAdding: .day, value: 1, to: start) ?? start) : start
                bars.append(ExpiredBar(start: start, end: end, pct: e.fleetPct ?? 0, events: [e]))
            }
        }
        self.bars = bars
        barMax = [2.0, 5, 10, 20, 50, 100].first { $0 >= (bars.map(\.pct).max() ?? 0) } ?? 100
        resetCount = sm?.resets ?? resets.count
        expiredPct = sm?.expiredUnusedPct
        expiredUnits = sm?.expiredUnusedUnits ?? resets.reduce(0) { $0 + $1.units }
        tiles.insert(StatTile(label: "Expired unused", value: expiredPct.map { "\(Int($0.rounded()))%" } ?? "—",
                              help: "Share of the weekly capacity that reset in the range without being used: \(resetCount) resets, about \(String(format: "%.1f", expiredUnits / 7)) Max 20x weeks"), at: 3)
        self.tiles = tiles

        var note = range.fleetStepLabel.map { "one point per \($0)" } ?? "a point every \(Int((resp.intervalMs ?? 300_000) / 60_000)) min"
        note += " · same math as the fleet bar: plan-weighted, an account counts its binding window"
        if clipped { note += " · history starts \(domain.lowerBound.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" }
        footnote = note
    }
}

struct FleetReset {
    let account: String
    let label: String
    let tier: String?
    let date: Date
    let unusedPct: Double
    let units: Double
    let weight: Double
    let fleetPct: Double?
    let approx: Bool
}

struct ExpiredBar: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    var pct: Double
    var events: [FleetReset]
}

/// "1.0" Max 20x weeks, with two decimals under one so small amounts are not 0.0.
private func max20x(_ units: Double) -> String {
    let v = units / 7
    return v >= 1 || v == 0 ? String(format: "%.1f", v) : String(format: "%.2f", v)
}

/// An account whose weekly window resets within 48 h with capacity left.
struct ExpiringItem: Identifiable {
    var id: String { label }
    let label: String
    let tier: String?
    let at: Date
    let left: Double
    let fleetPct: Double?

    static func from(_ accounts: [AccountDTO], now: Date = Date()) -> [ExpiringItem] {
        let counted = accounts.filter { $0.usage?.session != nil || $0.usage?.weekly != nil }
        let w = counted.reduce(0) { $0 + SortColumn.planWeight($1.tier ?? "") }
        return accounts.compactMap { a -> ExpiringItem? in
            guard let wk = a.usage?.weekly, let pct = wk.pct, let at = TimeFmt.parse(wk.resetsAt) else { return nil }
            let left = max(0, 100 - pct)
            let dt = at.timeIntervalSince(now)
            guard left > 0, dt > 0, dt <= 48 * 3600 else { return nil }
            let wt = SortColumn.planWeight(a.tier ?? "")
            return ExpiringItem(label: a.name, tier: a.tier, at: at, left: left, fleetPct: w > 0 ? wt * left / w : nil)
        }
        .sorted { $0.at < $1.at }
    }
}

private struct SectionHead: View {
    let title: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title.uppercased()).font(Theme.mono(10.5, .regular)).tracking(1).foregroundColor(Theme.ink3)
            if let d = detail { Text(d).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4) }
        }
    }
}

private struct ExpiringSoon: View {
    let items: [ExpiringItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let total = items.reduce(0) { $0 + ($1.fleetPct ?? 0) }
            SectionHead(title: "Use it or lose it · next 48 h",
                        detail: items.isEmpty ? nil : String(format: "%.1f%% of the fleet's weekly capacity resets unused unless work moves to these accounts", total))
            if items.isEmpty {
                Text("No account resets in the next 48 hours with capacity left.").font(Theme.ui(12.5)).foregroundColor(Theme.ink4)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(items) { e in
                        GridRow {
                            Text(e.label).font(Theme.ui(12.5)).foregroundColor(Theme.ink2).lineLimit(1)
                            Text(e.tier ?? "").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
                            Text("\(Int(e.left.rounded()))% left").font(Theme.mono(12, .semibold)).foregroundColor(Theme.ink).gridColumnAlignment(.trailing)
                            Text(e.fleetPct.map { String(format: "%.1f%% of fleet", $0) } ?? "").font(Theme.mono(12, .regular)).foregroundColor(Theme.ink2).gridColumnAlignment(.trailing)
                            Countdown(target: e.at) { now in
                                Text("resets \(TimeFmt.inText(TimeFmt.iso.string(from: e.at), now: now)) · \(TimeFmt.dayClock(TimeFmt.iso.string(from: e.at)))")
                                    .font(Theme.mono(11.5, .regular)).foregroundColor(Theme.ink3)
                            }
                        }
                        Divider().background(Theme.hairSoft).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

private struct ExpiredTable: View {
    let data: FleetData
    private struct Group: Identifiable {
        var id: String { account }
        let account: String
        var label: String
        var tier: String?
        var n = 0
        var unused = 0.0
        var units = 0.0
        var approx = 0
    }
    private var groups: [Group] {
        // Grouped by name: a re-added account gets a new id but is the same seat.
        var m: [String: Group] = [:]
        for e in data.resets {
            var g = m[e.label] ?? Group(account: e.label, label: e.label, tier: e.tier)
            g.n += 1; g.unused += e.unusedPct; g.units += e.units; if e.approx { g.approx += 1 }
            m[e.label] = g
        }
        return m.values.sorted { $0.units != $1.units ? $0.units > $1.units : $0.label < $1.label }
    }

    var body: some View {
        let all = groups
        let wasted = all.filter { $0.units > 0 }
        let full = all.filter { $0.units <= 0 }.map(\.label)
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: "Expired unused in this range",
                        detail: data.resetCount == 0 ? nil : "\(data.resetCount) weekly resets · \(Int((data.expiredPct ?? 0).rounded()))% of the capacity that reset went unused · about \(max20x(data.expiredUnits)) Max 20x weeks")
            if wasted.isEmpty {
                Text(all.isEmpty ? "No weekly resets in this range yet." : "Every account used its whole week at every reset in this range.")
                    .font(Theme.ui(12.5)).foregroundColor(Theme.ink4)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["ACCOUNT", "PLAN", "RESETS", "AVG UNUSED", "MAX 20X WEEKS"], id: \.self) { h in
                            Text(h).font(Theme.mono(10, .regular)).tracking(0.8).foregroundColor(Theme.ink4)
                        }
                    }
                    Divider().background(Theme.hair).gridCellUnsizedAxes(.horizontal)
                    ForEach(wasted) { g in
                        GridRow {
                            HStack(spacing: 6) {
                                Text(g.label).font(Theme.ui(12.5)).foregroundColor(Theme.ink2).lineLimit(1)
                                if g.approx > 0 {
                                    Text("~").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
                                        .help("The last reading before at least one of these resets was over an hour old (engine off or cached), so its unused share is approximate")
                                }
                            }
                            Text(g.tier ?? "").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
                            Text("\(g.n)").font(Theme.mono(12, .regular)).foregroundColor(Theme.ink2).gridColumnAlignment(.trailing)
                            Text("\(Int((g.unused / Double(g.n)).rounded()))%").font(Theme.mono(12, .semibold)).foregroundColor(Theme.ink).gridColumnAlignment(.trailing)
                            Text(max20x(g.units)).font(Theme.mono(12, .regular)).foregroundColor(Theme.ink2).gridColumnAlignment(.trailing)
                        }
                        Divider().background(Theme.hairSoft).gridCellUnsizedAxes(.horizontal)
                    }
                }
                if !full.isEmpty {
                    Text("Used the whole week at every reset: \(full.joined(separator: ", "))").font(Theme.ui(12)).foregroundColor(Theme.ink4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

private enum FleetColor {
    static let locked = Color(hex: 0x3987e5)
    static let soon = Color(hex: 0x199e70)
    static let blocked = Color(hex: 0xd95926)
    static let pace = Theme.ink2
    static let expired = Theme.ink3
}

private struct FleetLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            key(AnyView(AreaSwatch(color: FleetColor.locked, opacity: 0.85)), "Locked until a weekly reset")
            key(AnyView(AreaSwatch(color: FleetColor.soon, opacity: 0.6)), "Back within 5h")
            key(AnyView(LineSwatch(color: FleetColor.blocked, dashed: false)), "Accounts blocked")
            key(AnyView(LineSwatch(color: FleetColor.pace, dashed: false)), "Weekly burn vs pace")
            key(AnyView(AreaSwatch(color: FleetColor.expired, opacity: 0.7)), "Expired unused at reset")
        }
    }
    private func key(_ sw: AnyView, _ label: String) -> some View {
        HStack(spacing: 7) { sw; Text(label).font(Theme.ui(12.5)).foregroundColor(Theme.ink2).lineLimit(1) }
    }
}

private struct AreaSwatch: View {
    let color: Color
    let opacity: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(color.opacity(opacity)).frame(width: 13, height: 9)
    }
}

// MARK: - Panels

private enum Panel: Hashable { case capacity, blocked, pace, expired }

private struct PanelAnchorsKey: PreferenceKey {
    static let defaultValue: [Panel: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Panel: Anchor<CGRect>], nextValue: () -> [Panel: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Same y-axis label width on every panel, so their plot areas line up.
private func axisLabel(_ s: String) -> some View {
    Text(s).font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3).frame(width: 34, alignment: .trailing)
}

private func panelTitle(_ s: String) -> some View {
    Text(s.uppercased()).font(Theme.mono(10, .regular)).tracking(0.8).foregroundColor(Theme.ink3)
        .padding(.leading, 42)
}

private struct FleetPanels: View {
    let data: FleetData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapacityChart(data: data).equatable().frame(height: 220)
            panelTitle("Accounts blocked").padding(.top, 6)
            BlockedChart(data: data).equatable().frame(height: 74)
            panelTitle("Weekly burn vs sustainable pace").padding(.top, 6)
            PaceChart(data: data).equatable().frame(height: 74)
            panelTitle("Expired unused at weekly resets (% of fleet week\(data.perDay ? ", per day" : ""))").padding(.top, 6)
            ExpiredChart(data: data).equatable().frame(height: 84)
        }
        .padding(.trailing, 16)
        .overlayPreferenceValue(PanelAnchorsKey.self) { anchors in
            GeometryReader { geo in
                if let a = anchors[.capacity], let b = anchors[.blocked], let c = anchors[.pace], let d = anchors[.expired] {
                    FleetHover(data: data, capacity: geo[a], blocked: geo[b], pace: geo[c], expired: geo[d])
                }
            }
        }
    }
}

private struct CapacityChart: View, Equatable {
    let data: FleetData
    static func == (a: Self, b: Self) -> Bool { a.data.id == b.data.id }

    var body: some View {
        Chart {
            ForEach(Array(data.runs.enumerated()), id: \.offset) { i, run in
                ForEach(Array(run.enumerated()), id: \.offset) { _, s in
                    AreaMark(x: .value("Time", s.date), yStart: .value("From", 0), yEnd: .value("Locked", min(100, s.locked)), series: .value("Run", "L\(i)"))
                        .foregroundStyle(FleetColor.locked.opacity(0.85))
                }
                ForEach(Array(run.enumerated()), id: \.offset) { _, s in
                    AreaMark(x: .value("Time", s.date), yStart: .value("Locked", min(100, s.locked)), yEnd: .value("Used", min(100, s.locked + s.soon)), series: .value("Run", "S\(i)"))
                        .foregroundStyle(FleetColor.soon.opacity(0.6))
                }
            }
            ForEach([Theme.warnPct, Theme.critPct], id: \.self) { v in
                RuleMark(y: .value("Threshold", v))
                    .foregroundStyle(Theme.ink4)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("\(Int(v))").font(Theme.mono(9.5, .regular)).foregroundColor(Theme.ink4)
                    }
            }
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel { if let n = v.as(Int.self) { axisLabel("\(n)%") } }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in Color.clear.preference(key: PanelAnchorsKey.self, value: [.capacity: proxy.plotAreaFrame]) }
    }
}

private struct BlockedChart: View, Equatable {
    let data: FleetData
    static func == (a: Self, b: Self) -> Bool { a.data.id == b.data.id }

    var body: some View {
        Chart {
            ForEach(Array(data.runs.enumerated()), id: \.offset) { i, run in
                ForEach(Array(run.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("Time", s.date), y: .value("Blocked", s.blocked), series: .value("Run", "B\(i)"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(FleetColor.blocked)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...data.maxAccounts)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, data.maxAccounts]) { v in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel { if let n = v.as(Int.self) { axisLabel("\(n)") } }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in Color.clear.preference(key: PanelAnchorsKey.self, value: [.blocked: proxy.plotAreaFrame]) }
    }
}

private struct PaceChart: View, Equatable {
    let data: FleetData
    static func == (a: Self, b: Self) -> Bool { a.data.id == b.data.id }

    /// Runs of points with a pace value (it is nil while no weekly window has
    /// enough elapsed time to judge).
    private var paceRuns: [(id: String, points: [(Date, Double)])] {
        var out: [(String, [(Date, Double)])] = []
        for (i, run) in data.runs.enumerated() {
            var cur: [(Date, Double)] = []
            var n = 0
            for s in run {
                if let p = s.pace { cur.append((s.date, min(p, data.paceMax))) }
                else if !cur.isEmpty { out.append(("P\(i)-\(n)", cur)); cur = []; n += 1 }
            }
            if !cur.isEmpty { out.append(("P\(i)-\(n)", cur)) }
        }
        return out.map { (id: $0.0, points: $0.1) }
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Sustainable", 1))
                .foregroundStyle(Theme.ink4)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            ForEach(paceRuns, id: \.id) { r in
                ForEach(Array(r.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value("Pace", p.1), series: .value("Run", r.id))
                        .foregroundStyle(FleetColor.pace)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...data.paceMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: [1, data.paceMax]) { v in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel { if let n = v.as(Double.self) { axisLabel(n == n.rounded() ? "\(Int(n))×" : String(format: "%.1f×", n)) } }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in Color.clear.preference(key: PanelAnchorsKey.self, value: [.pace: proxy.plotAreaFrame]) }
    }
}

private struct ExpiredChart: View, Equatable {
    let data: FleetData
    static func == (a: Self, b: Self) -> Bool { a.data.id == b.data.id }

    private var fill: Color { FleetColor.expired.opacity(0.7) }

    @ChartContentBuilder private var marks: some ChartContent {
        if data.perDay {
            ForEach(data.bars) { (b: ExpiredBar) in
                let top: Double = min(b.pct, data.barMax)
                RectangleMark(xStart: .value("From", b.start), xEnd: .value("To", b.end), yStart: .value("Zero", 0.0), yEnd: .value("Expired", top))
                    .foregroundStyle(fill)
            }
        } else {
            ForEach(data.bars) { (b: ExpiredBar) in
                let top: Double = min(b.pct, data.barMax)
                BarMark(x: .value("Time", b.start), yStart: .value("Zero", 0.0), yEnd: .value("Expired", top), width: .fixed(5))
                    .foregroundStyle(fill)
            }
        }
    }

    var body: some View {
        Chart { marks }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...data.barMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, data.barMax]) { v in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel { if let n = v.as(Double.self) { axisLabel("\(Int(n))%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(data.range.tickLabel(d)).font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3) }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in Color.clear.preference(key: PanelAnchorsKey.self, value: [.expired: proxy.plotAreaFrame]) }
    }
}

// MARK: - Hover

private struct FleetHover: View {
    let data: FleetData
    let capacity: CGRect
    let blocked: CGRect
    let pace: CGRect
    let expired: CGRect
    @State private var index: Int?

    private var span: Double { max(1, data.domain.upperBound.timeIntervalSince(data.domain.lowerBound)) }
    private func x(_ d: Date, in r: CGRect) -> CGFloat { r.minX + CGFloat(d.timeIntervalSince(data.domain.lowerBound) / span) * r.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    let next: Int?
                    switch phase {
                    case .active(let loc):
                        let t = data.domain.lowerBound.addingTimeInterval(Double((loc.x - capacity.minX) / max(1, capacity.width)) * span)
                        let i = Self.nearest(data.samples, to: t)
                        next = i.flatMap { abs(data.samples[$0].date.timeIntervalSince(t)) <= data.range.fleetGapSeconds ? $0 : nil }
                    case .ended:
                        next = nil
                    }
                    if next != index { index = next }
                }
            if let i = index {
                let s = data.samples[i]
                ForEach([capacity, blocked, pace, expired], id: \.minY) { r in
                    let cx = x(s.date, in: r)
                    Path { p in p.move(to: CGPoint(x: cx, y: r.minY)); p.addLine(to: CGPoint(x: cx, y: r.maxY)) }
                        .stroke(Theme.ink3, lineWidth: 1)
                }
                .allowsHitTesting(false)
                dot(FleetColor.soon, x(s.date, in: capacity), capacity.minY + CGFloat(1 - min(100, s.locked + s.soon) / 100) * capacity.height)
                dot(FleetColor.locked, x(s.date, in: capacity), capacity.minY + CGFloat(1 - min(100, s.locked) / 100) * capacity.height)
                dot(FleetColor.blocked, x(s.date, in: blocked), blocked.minY + CGFloat(1 - Double(s.blocked) / Double(data.maxAccounts)) * blocked.height)
                if let p = s.pace {
                    dot(FleetColor.pace, x(s.date, in: pace), pace.minY + CGFloat(1 - min(p, data.paceMax) / data.paceMax) * pace.height)
                }
                let cx = x(s.date, in: capacity)
                tooltip(s)
                    .fixedSize()
                    .alignmentGuide(.leading) { dim in cx + 14 + dim.width > capacity.maxX ? -(cx - 14 - dim.width) : -(cx + 14) }
                    .alignmentGuide(.top) { _ in -(capacity.minY + 6) }
                    .allowsHitTesting(false)
            }
        }
    }

    private func dot(_ c: Color, _ x: CGFloat, _ y: CGFloat) -> some View {
        Circle().fill(c).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }

    private func tooltip(_ s: FleetSample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                 + (s.stale > 0 ? " · \(s.stale) cached" : ""))
                .font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
            row(AnyView(AreaSwatch(color: Theme.ink3, opacity: 0.5)), "Used", "\(Int(s.used.rounded()))%")
            row(AnyView(AreaSwatch(color: FleetColor.locked, opacity: 0.85)), "  locked until weekly", "\(Int(s.locked.rounded()))%")
            row(AnyView(AreaSwatch(color: FleetColor.soon, opacity: 0.6)), "  back within 5h", "\(Int(s.soon.rounded()))%")
            row(AnyView(AreaSwatch(color: Theme.hair, opacity: 1)), "Free", "\(Int(s.free.rounded()))%")
            row(AnyView(LineSwatch(color: FleetColor.blocked, dashed: false)), "Blocked", "\(s.blocked) of \(s.total)")
            row(AnyView(LineSwatch(color: FleetColor.pace, dashed: false)), "Weekly burn", s.pace.map { String(format: "%.1f× pace", $0) } ?? "—")
            if let b = expiredBar(near: s.date) {
                let evs = b.events.sorted { $0.units > $1.units }
                row(AnyView(AreaSwatch(color: FleetColor.expired, opacity: 0.7)), "Expired unused",
                    (data.perDay ? b.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                 : evs[0].date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    + String(format: ": %.1f%% of fleet week", b.pct))
                ForEach(Array(evs.prefix(3).enumerated()), id: \.offset) { _, e in
                    row(AnyView(Color.clear.frame(width: 13, height: 9)), e.label, "\(Int(e.unusedPct.rounded()))% unused\(e.approx ? " ~" : "")")
                }
                if evs.count > 3 { row(AnyView(Color.clear.frame(width: 13, height: 9)), "+\(evs.count - 3) more", "") }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    private func row(_ sw: AnyView, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            sw.frame(width: 18)
            Text(label).font(Theme.ui(12)).foregroundColor(Theme.ink2)
            Spacer(minLength: 16)
            Text(value).font(Theme.mono(12, .semibold)).foregroundColor(Theme.ink)
        }
    }

    /// The hovered day's bar (30d / 90d), or the closest reset bar within reach.
    private func expiredBar(near t: Date) -> ExpiredBar? {
        if data.perDay { return data.bars.first { t >= $0.start && t < $0.end } }
        let reach = max(data.range.fleetGapSeconds, span / 120)
        return data.bars.filter { abs($0.start.timeIntervalSince(t)) <= reach }
            .min { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }
    }

    static func nearest(_ samples: [FleetSample], to t: Date) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].date < t { lo = mid } else { hi = mid }
        }
        return abs(samples[hi].date.timeIntervalSince(t)) < abs(samples[lo].date.timeIntervalSince(t)) ? hi : lo
    }
}

// MARK: - DTOs

struct FleetHistoryResp: Decodable {
    struct Point: Decodable {
        var ts: String
        var usedPct: Double?
        var freePct: Double?
        var backSoonPct: Double?
        var lockedPct: Double?
        var blocked: Int?
        var total: Int?
        var paceRatio: Double?
        var stale: Int?
    }
    struct Summary: Decodable {
        var avgUsedPct: Double?
        var maxUsedPct: Double?
        var minFreePct: Double?
        var peakBlocked: Int?
        var blockedMs: Double?
        var atLimitMs: Double?
        var avgPaceRatio: Double?
        var maxAccounts: Int?
        var resets: Int?
        var expiredUnusedPct: Double?
        var expiredUnusedUnits: Double?
    }
    struct Reset: Decodable {
        var account: String
        var label: String?
        var tier: String?
        var weight: Double?
        var at: String
        var unusedPct: Double?
        var units: Double?
        var fleetPct: Double?
        var approx: Bool?
    }
    var points: [Point]
    var resets: [Reset]?
    var summary: Summary?
    var intervalMs: Double?
}
