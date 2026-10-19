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
    let accountCount: Int
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

            VStack(alignment: .leading, spacing: 14) {
                Picker("Range", selection: $rangeRaw) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                FleetLegend()
                if let d = data { StatTiles(tiles: d.tiles) }
                chartArea.frame(minHeight: 380)
                Text(data?.footnote ?? " ").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            }
            .padding(20)
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 640, idealHeight: 700)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        self.tiles = tiles

        var note = range.fleetStepLabel.map { "one point per \($0)" } ?? "a point every \(Int((resp.intervalMs ?? 300_000) / 60_000)) min"
        note += " · same math as the fleet bar: plan-weighted, an account counts its binding window"
        if clipped { note += " · history starts \(domain.lowerBound.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" }
        footnote = note
    }
}

private enum FleetColor {
    static let locked = Color(hex: 0x3987e5)
    static let soon = Color(hex: 0x199e70)
    static let blocked = Color(hex: 0xd95926)
    static let pace = Theme.ink2
}

private struct FleetLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            key(AnyView(AreaSwatch(color: FleetColor.locked, opacity: 0.85)), "Locked until a weekly reset")
            key(AnyView(AreaSwatch(color: FleetColor.soon, opacity: 0.6)), "Back within 5h")
            key(AnyView(LineSwatch(color: FleetColor.blocked, dashed: false)), "Accounts blocked")
            key(AnyView(LineSwatch(color: FleetColor.pace, dashed: false)), "Weekly burn vs pace")
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

private enum Panel: Hashable { case capacity, blocked, pace }

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
            CapacityChart(data: data).equatable().frame(minHeight: 200)
            panelTitle("Accounts blocked").padding(.top, 6)
            BlockedChart(data: data).equatable().frame(height: 74)
            panelTitle("Weekly burn vs sustainable pace").padding(.top, 6)
            PaceChart(data: data).equatable().frame(height: 74)
        }
        .padding(.trailing, 16)
        .overlayPreferenceValue(PanelAnchorsKey.self) { anchors in
            GeometryReader { geo in
                if let a = anchors[.capacity], let b = anchors[.blocked], let c = anchors[.pace] {
                    FleetHover(data: data, capacity: geo[a], blocked: geo[b], pace: geo[c])
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
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(data.range.tickLabel(d)).font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3) }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in Color.clear.preference(key: PanelAnchorsKey.self, value: [.pace: proxy.plotAreaFrame]) }
    }
}

// MARK: - Hover

private struct FleetHover: View {
    let data: FleetData
    let capacity: CGRect
    let blocked: CGRect
    let pace: CGRect
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
                ForEach([capacity, blocked, pace], id: \.minY) { r in
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
    }
    var points: [Point]
    var summary: Summary?
    var intervalMs: Double?
}
