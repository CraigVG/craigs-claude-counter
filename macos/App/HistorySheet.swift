import SwiftUI
import Charts

/// One account's usage over time, opened by clicking its row. Reads the
/// engine's history log (GET /api/history + /api/history/summary). Mirrors
/// the web view: ranges, gap rules and colors follow src/usage-chart.mjs.
///
/// Performance: everything the chart draws is built once per load
/// (`HistoryData`), the chart is an equatable view that only redraws when that
/// data changes, and hover lives in a sibling layer, so moving the pointer
/// redraws only the crosshair. The sheet does not observe the model: each
/// 30-second usage poll would otherwise redraw the chart.
struct HistorySheet: View {
    let model: CounterModel
    let account: AccountDTO
    @Environment(\.dismiss) private var dismiss
    @AppStorage("historyRange") private var rangeRaw = HistoryRange.week.rawValue

    @State private var data: HistoryData?
    @State private var loading = true
    @State private var failure: String?

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(account.name).font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let t = account.tier { Text(t).font(Theme.mono(11.5, .regular)).foregroundColor(Theme.ink3) }
                Spacer()
                Button { dismiss() } label: { Text("✕").font(Theme.ui(14)).foregroundColor(Theme.ink3) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Rectangle().fill(Theme.hair).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Picker("Range", selection: $rangeRaw) {
                        ForEach(HistoryRange.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if let d = data { Legend(series: d.series) }
                    Spacer()
                }
                if let d = data { StatTiles(tiles: d.tiles) }
                chartArea.frame(minHeight: 280)
                Text(data?.footnote ?? " ").font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            }
            .padding(20)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 540, idealHeight: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task(id: rangeRaw) { await load() }
    }

    private func load() async {
        loading = true
        failure = nil
        let r = range
        do {
            let (recs, sum, interval) = try await model.history(accountId: account.id, range: r)
            data = HistoryData(records: recs, summary: sum, intervalMs: interval ?? 300_000, range: r)
        } catch {
            failure = "Could not load history (\(error.localizedDescription)). Is the engine running?"
        }
        loading = false
    }

    @ViewBuilder private var chartArea: some View {
        if let f = failure {
            centered(f)
        } else if let d = data, !d.samples.isEmpty {
            ChartWithHover(data: d)
        } else if loading {
            centered("Loading…")
        } else {
            centered("No history for this account in this range yet. The engine logs every account every few minutes.")
        }
    }

    private func centered(_ s: String) -> some View {
        Text(s).font(Theme.ui(13)).foregroundColor(Theme.ink3).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Prepared data

/// One parsed sample. Dates are parsed once here, never during drawing.
struct HistorySample {
    let date: Date
    let session: Double?
    let weekly: Double?
    let model: Double?
    let stale: Bool
    let error: String?
}

/// Everything the sheet shows for one load, computed once.
struct HistoryData {
    let id = UUID()
    let range: HistoryRange
    let samples: [HistorySample]
    let series: [HistorySeries]
    let lines: [ChartLine]
    let domain: ClosedRange<Date>
    let tiles: [StatTile]
    let footnote: String

    init(records: [HistoryRecordDTO], summary: HistorySummaryDTO?, intervalMs: Double, range: HistoryRange) {
        self.range = range
        let modelName = records.lazy.compactMap { $0.models?.first?.name }.first
        let samples = records.compactMap { r -> HistorySample? in
            guard let d = TimeFmt.parse(r.ts) else { return nil }
            let m = modelName.flatMap { n in r.models?.first(where: { $0.name == n })?.pct }
            return HistorySample(date: d, session: r.session?.pct, weekly: r.weekly?.pct, model: m, stale: r.stale == true, error: r.error)
        }
        self.samples = samples
        self.series = HistorySeries.all(modelName: modelName)

        let until = Date(), want = until.addingTimeInterval(-range.seconds)
        let clipped = samples.first.map { $0.date.timeIntervalSince(want) > range.seconds * 0.1 } ?? false
        let domain = (clipped ? samples[0].date : want)...until
        self.domain = domain
        self.lines = ChartLine.build(samples: samples, series: series, gapSeconds: range.gapSeconds, domain: domain)
        self.tiles = StatTile.from(summary, intervalMs: intervalMs)

        let every = range.stepLabel.map { "one sample per \($0)" } ?? "a sample every \(Int(intervalMs / 60_000)) min"
        var note = "\(every) · gaps = engine off or account unavailable"
        if clipped { note += " · history starts \(domain.lowerBound.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" }
        self.footnote = note
    }
}

/// One unbroken run of one series, thinned for drawing. Runs break at gaps
/// so a line never bridges a stretch with no data.
struct ChartLine: Identifiable {
    struct Point { let date: Date; let value: Double }
    let id: String
    let series: HistorySeries
    let points: [Point]

    /// About this many buckets across the domain; each keeps its lowest and
    /// highest sample in time order, so peaks and resets survive the thinning
    /// while a 7-day chart draws ~1,000 points per line instead of ~2,000.
    static let buckets = 500.0

    static func build(samples: [HistorySample], series: [HistorySeries], gapSeconds: Double, domain: ClosedRange<Date>) -> [ChartLine] {
        let bucketSecs = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / buckets)
        var out: [ChartLine] = []
        for s in series.sorted(by: { $0.drawOrder < $1.drawOrder }) {
            var runs: [[Point]] = []
            var run: [Point] = []
            var last: Date?
            for x in samples {
                guard let v = s.value(x) else {
                    if !run.isEmpty { runs.append(run); run = [] }
                    last = x.date
                    continue
                }
                if let l = last, x.date.timeIntervalSince(l) > gapSeconds, !run.isEmpty { runs.append(run); run = [] }
                run.append(Point(date: x.date, value: min(100, max(0, v))))
                last = x.date
            }
            if !run.isEmpty { runs.append(run) }
            for (i, r) in runs.enumerated() {
                out.append(ChartLine(id: "\(s.id)-\(i)", series: s, points: thin(r, bucketSecs: bucketSecs, origin: domain.lowerBound)))
            }
        }
        return out
    }

    static func thin(_ pts: [Point], bucketSecs: Double, origin: Date) -> [Point] {
        guard pts.count > 2 else { return pts }
        var out: [Point] = []
        out.reserveCapacity(pts.count)
        var i = 0
        while i < pts.count {
            let b = Int(pts[i].date.timeIntervalSince(origin) / bucketSecs)
            var lo = i, hi = i, j = i + 1
            while j < pts.count, Int(pts[j].date.timeIntervalSince(origin) / bucketSecs) == b {
                if pts[j].value < pts[lo].value { lo = j }
                if pts[j].value > pts[hi].value { hi = j }
                j += 1
            }
            for k in [i, min(lo, hi), max(lo, hi)] where out.last.map({ $0.date != pts[k].date }) ?? true {
                out.append(pts[k])
            }
            i = j
        }
        if let l = pts.last, out.last?.date != l.date { out.append(l) }
        return out
    }
}

struct StatTile {
    let label: String
    let value: String
    let help: String

    static func from(_ s: HistorySummaryDTO?, intervalMs: Double) -> [StatTile] {
        guard let s = s else { return [] }
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }
        var out = [
            StatTile(label: "Weekly avg", value: pct(s.weekly?.avg), help: "Average weekly (all models) usage over the range"),
            StatTile(label: "Weekly peak", value: pct(s.weekly?.max), help: "Highest weekly usage in the range"),
            StatTile(label: "Session peak", value: pct(s.session?.max), help: "Highest 5-hour session usage in the range"),
            StatTile(label: "At limit", value: duration(Double(s.atLimitSamples ?? 0) * intervalMs / 1000),
                     help: "Time with session or weekly at \(Int(Theme.critPct))% or more (from \(Int(intervalMs / 60_000))-minute samples)"),
            StatTile(label: "Weekly resets", value: "\(s.resets?.weekly ?? 0)", help: "How many times the weekly window reset in the range"),
        ]
        if let o = s.overage {
            out.append(StatTile(label: "Overage spent", value: usd(o.spentUsd ?? max(0, o.deltaUsd ?? 0)),
                                help: "Extra-usage dollars added in the range (billing-cycle resets do not subtract)"))
        }
        return out
    }

    static func duration(_ secs: Double) -> String {
        let m = Int((secs / 60).rounded())
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }
}

// MARK: - Pieces

private struct Legend: View {
    let series: [HistorySeries]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(series) { s in
                HStack(spacing: 7) {
                    LineSwatch(color: s.color, dashed: s.dashed)
                    Text(s.label).font(Theme.ui(12.5)).foregroundColor(Theme.ink2)
                }
            }
        }
    }
}

struct StatTiles: View {
    let tiles: [StatTile]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(tiles, id: \.label) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.label.uppercased()).font(Theme.mono(10, .regular)).tracking(1).foregroundColor(Theme.ink3)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(t.value).font(Theme.mono(17, .semibold)).foregroundColor(Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairSoft, lineWidth: 1))
                .help(t.help)
            }
        }
    }
}

private struct PlotFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The chart plus its hover layer. The chart reports its plot rectangle once
/// (and on resize); the hover layer maps pointer <-> time itself with that
/// rectangle, so hovering never touches the chart.
private struct ChartWithHover: View {
    let data: HistoryData
    @State private var plot = CGRect.zero

    var body: some View {
        UsageChart(data: data)
            .equatable()
            .onPreferenceChange(PlotFrameKey.self) { plot = $0 }
            .overlay {
                if plot.width > 0 {
                    HoverLayer(samples: data.samples, series: data.series, domain: data.domain, plot: plot, gapSeconds: data.range.gapSeconds)
                }
            }
            .padding(.trailing, 16)   // room for the last date label
    }
}

private struct UsageChart: View, Equatable {
    let data: HistoryData
    static func == (a: Self, b: Self) -> Bool { a.data.id == b.data.id }

    var body: some View {
        Chart {
            ForEach([Theme.warnPct, Theme.critPct], id: \.self) { v in
                RuleMark(y: .value("Threshold", v))
                    .foregroundStyle(Theme.ink4)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("\(Int(v))").font(Theme.mono(9.5, .regular)).foregroundColor(Theme.ink4)
                    }
            }
            ForEach(data.lines) { line in
                let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: line.series.dashed ? [5, 4] : [])
                ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.date), y: .value("Usage", p.value), series: .value("Run", line.id))
                        .foregroundStyle(line.series.color)
                        .lineStyle(style)
                }
            }
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3) } }
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear.preference(key: PlotFrameKey.self, value: geo[proxy.plotAreaFrame])
            }
        }
    }
}

private struct HoverLayer: View {
    let samples: [HistorySample]
    let series: [HistorySeries]
    let domain: ClosedRange<Date>
    let plot: CGRect
    let gapSeconds: Double
    @State private var index: Int?

    private var span: Double { max(1, domain.upperBound.timeIntervalSince(domain.lowerBound)) }
    private func x(_ d: Date) -> CGFloat { plot.minX + CGFloat(d.timeIntervalSince(domain.lowerBound) / span) * plot.width }
    private func y(_ v: Double) -> CGFloat { plot.minY + CGFloat(1 - min(100, max(0, v)) / 100) * plot.height }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    let next: Int?
                    switch phase {
                    case .active(let loc):
                        let t = domain.lowerBound.addingTimeInterval(Double((loc.x - plot.minX) / max(1, plot.width)) * span)
                        let i = Self.nearest(samples, to: t)
                        next = i.flatMap { abs(samples[$0].date.timeIntervalSince(t)) <= gapSeconds ? $0 : nil }
                    case .ended:
                        next = nil
                    }
                    if next != index { index = next }   // only redraw when the sample changes
                }
            if let i = index {
                let sample = samples[i]
                let cx = x(sample.date)
                Path { p in p.move(to: CGPoint(x: cx, y: plot.minY)); p.addLine(to: CGPoint(x: cx, y: plot.maxY)) }
                    .stroke(Theme.ink3, lineWidth: 1)
                    .allowsHitTesting(false)
                ForEach(series) { s in
                    if let v = s.value(sample) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .position(x: cx, y: y(v))
                            .allowsHitTesting(false)
                    }
                }
                tooltip(sample)
                    .fixedSize()
                    .alignmentGuide(.leading) { dim in cx + 14 + dim.width > plot.maxX ? -(cx - 14 - dim.width) : -(cx + 14) }
                    .alignmentGuide(.top) { _ in -(plot.minY + 6) }
                    .allowsHitTesting(false)
            }
        }
    }

    private func tooltip(_ r: HistorySample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let flags = [r.stale ? "cached" : nil, r.error?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }
            Text(r.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                 + (flags.isEmpty ? "" : " · " + flags.joined(separator: " · ")))
                .font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3)
            ForEach(series) { s in
                HStack(spacing: 8) {
                    LineSwatch(color: s.color, dashed: s.dashed)
                    Text(s.label).font(Theme.ui(12)).foregroundColor(Theme.ink2)
                    Spacer(minLength: 16)
                    Text(s.value(r).map { "\(Int($0.rounded()))%" } ?? "—").font(Theme.mono(12, .semibold)).foregroundColor(Theme.ink)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    /// Index of the sample nearest to `t` (samples sorted by time).
    static func nearest(_ samples: [HistorySample], to t: Date) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].date < t { lo = mid } else { hi = mid }
        }
        return abs(samples[hi].date.timeIntervalSince(t)) < abs(samples[lo].date.timeIntervalSince(t)) ? hi : lo
    }
}

struct LineSwatch: View {
    let color: Color
    let dashed: Bool
    var body: some View {
        Path { p in p.move(to: CGPoint(x: 1, y: 4)); p.addLine(to: CGPoint(x: 17, y: 4)) }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 8)
    }
}

// MARK: - Model

/// Time ranges; mirrors RANGES in src/usage-chart.mjs.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d", quarter = "90d"
    var id: String { rawValue }
    var label: String { rawValue }
    var seconds: Double {
        switch self { case .day: return 86_400; case .week: return 7 * 86_400; case .month: return 30 * 86_400; case .quarter: return 90 * 86_400 }
    }
    /// Downsampling step sent to the engine (first sample per bucket).
    var step: String? {
        switch self { case .day, .week: return nil; case .month: return "30m"; case .quarter: return "2h" }
    }
    var stepLabel: String? {
        switch self { case .day, .week: return nil; case .month: return "30 min"; case .quarter: return "2 h" }
    }
    /// Samples further apart than this are not joined by a line.
    var gapSeconds: Double {
        switch self { case .day, .week: return 20 * 60; case .month: return 2 * 3600; case .quarter: return 8 * 3600 }
    }
    /// The fleet chart thins harder; mirrors FLEET_STEPS in src/usage-chart.mjs.
    var fleetStep: String? {
        switch self { case .day: return nil; case .week: return "15m"; case .month: return "1h"; case .quarter: return "3h" }
    }
    var fleetStepLabel: String? {
        switch self { case .day: return nil; case .week: return "15 min"; case .month: return "hour"; case .quarter: return "3 h" }
    }
    var fleetGapSeconds: Double {
        let step: Double
        switch self { case .day: step = 0; case .week: step = 15 * 60; case .month: step = 3600; case .quarter: step = 3 * 3600 }
        return max(gapSeconds, 3 * step)
    }
    func tickLabel(_ d: Date) -> String {
        switch self {
        case .day:
            return Calendar.current.component(.hour, from: d) == 0
                ? d.formatted(.dateTime.weekday(.abbreviated).day()) : d.formatted(.dateTime.hour())
        case .week: return d.formatted(.dateTime.weekday(.abbreviated).day())
        case .month, .quarter: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// A drawn series. Colors are the validated set used by the web view:
/// weekly blue, session aqua, per-model weekly orange (dashed).
struct HistorySeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let dashed: Bool
    let drawOrder: Int
    let value: (HistorySample) -> Double?

    static func all(modelName: String?) -> [HistorySeries] {
        var out = [
            HistorySeries(id: "weekly", label: "Weekly", color: Color(hex: 0x3987e5), dashed: false, drawOrder: 2) { $0.weekly },
            HistorySeries(id: "session", label: "Session (5h)", color: Color(hex: 0x199e70), dashed: false, drawOrder: 0) { $0.session },
        ]
        if let name = modelName {
            out.append(HistorySeries(id: "model", label: "\(name) weekly", color: Color(hex: 0xd95926), dashed: true, drawOrder: 1) { $0.model })
        }
        return out
    }
}

struct HistoryRecordDTO: Decodable {
    struct Win: Decodable { var pct: Double? }
    struct Model: Decodable { var name: String; var pct: Double? }
    var ts: String
    var account: String
    var session: Win?
    var weekly: Win?
    var models: [Model]?
    var stale: Bool?
    var error: String?
}

struct HistoryResp: Decodable { var records: [HistoryRecordDTO] }

struct HistorySummaryDTO: Decodable {
    struct Stats: Decodable { var avg: Double?; var max: Double? }
    struct Resets: Decodable { var weekly: Int? }
    struct Overage: Decodable { var deltaUsd: Double?; var spentUsd: Double? }
    var account: String
    var session: Stats?
    var weekly: Stats?
    var resets: Resets?
    var overage: Overage?
    var atLimitSamples: Int?
}

struct HistorySummaryResp: Decodable {
    var intervalMs: Double?
    var accounts: [HistorySummaryDTO]
}
