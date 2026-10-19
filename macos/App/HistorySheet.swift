import SwiftUI
import Charts

/// One account's usage over time, opened by clicking its row. Reads the
/// engine's history log (GET /api/history + /api/history/summary). Mirrors
/// the web view: ranges, gap rules and colors follow src/usage-chart.mjs.
struct HistorySheet: View {
    @ObservedObject var model: CounterModel
    let account: AccountDTO
    @Environment(\.dismiss) private var dismiss
    @AppStorage("historyRange") private var rangeRaw = HistoryRange.week.rawValue

    @State private var records: [HistoryRecordDTO] = []
    @State private var summary: HistorySummaryDTO?
    @State private var intervalMs: Double = 300_000
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
                    legend
                    Spacer()
                }
                stats
                chartArea.frame(minHeight: 280)
                Text(footnote).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink4)
            }
            .padding(20)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 540, idealHeight: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task(id: rangeRaw) { await load() }
    }

    // MARK: data

    private func load() async {
        loading = true
        failure = nil
        do {
            let (recs, sum, interval) = try await model.history(accountId: account.id, range: range)
            records = recs
            summary = sum
            intervalMs = interval ?? intervalMs
        } catch {
            failure = "Could not load history (\(error.localizedDescription)). Is the engine running?"
        }
        loading = false
    }

    private var series: [HistorySeries] { HistorySeries.all(for: records) }

    /// The range, but starting where the log starts when it reaches further back.
    private var domain: ClosedRange<Date> {
        let until = Date(), want = until.addingTimeInterval(-range.seconds)
        guard let first = records.first?.date, first.timeIntervalSince(want) > range.seconds * 0.1 else { return want...until }
        return first...until
    }

    // MARK: pieces

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(series) { s in
                HStack(spacing: 7) {
                    LineSwatch(color: s.color, dashed: s.dashed)
                    Text(s.label).font(Theme.ui(12.5)).foregroundColor(Theme.ink2)
                }
            }
        }
    }

    private var stats: some View {
        let tiles = statTiles
        return HStack(spacing: 8) {
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

    private var statTiles: [(label: String, value: String, help: String)] {
        guard let s = summary else { return [] }
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }
        var out: [(String, String, String)] = [
            ("Weekly avg", pct(s.weekly?.avg), "Average weekly (all models) usage over the range"),
            ("Weekly peak", pct(s.weekly?.max), "Highest weekly usage in the range"),
            ("Session peak", pct(s.session?.max), "Highest 5-hour session usage in the range"),
            ("At limit", Self.duration(Double(s.atLimitSamples ?? 0) * intervalMs / 1000),
             "Time with session or weekly at \(Int(Theme.critPct))% or more (from \(Int(intervalMs / 60_000))-minute samples)"),
            ("Weekly resets", "\(s.resets?.weekly ?? 0)", "How many times the weekly window reset in the range"),
        ]
        if let o = s.overage {
            out.append(("Overage spent", usd(o.spentUsd ?? max(0, o.deltaUsd ?? 0)), "Extra-usage dollars added in the range (billing-cycle resets do not subtract)"))
        }
        return out.map { (label: $0.0, value: $0.1, help: $0.2) }
    }

    @ViewBuilder private var chartArea: some View {
        if let f = failure {
            centered(f)
        } else if loading && records.isEmpty {
            centered("Loading…")
        } else if records.isEmpty {
            centered("No history for this account in this range yet. The engine logs every account every few minutes.")
        } else {
            UsageChart(records: records, series: series, range: range, domain: domain)
        }
    }

    private func centered(_ s: String) -> some View {
        Text(s).font(Theme.ui(13)).foregroundColor(Theme.ink3).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footnote: String {
        let every = range.stepLabel.map { "one sample per \($0)" } ?? "a sample every \(Int(intervalMs / 60_000)) min"
        var s = "\(every) · gaps = engine off or account unavailable"
        let start = domain.lowerBound
        if start.timeIntervalSince(Date().addingTimeInterval(-range.seconds)) > range.seconds * 0.1 {
            s += " · history starts \(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        }
        return s
    }

    static func duration(_ secs: Double) -> String {
        let m = Int((secs / 60).rounded())
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }
}

// MARK: - Chart

/// The plot itself. Hover lives in its own child view so moving the pointer
/// redraws only the crosshair, not thousands of line marks.
private struct UsageChart: View {
    let records: [HistoryRecordDTO]
    let series: [HistorySeries]
    let range: HistoryRange
    let domain: ClosedRange<Date>

    /// One point per (series, run): runs break at gaps so a line never bridges
    /// a stretch with no data.
    private struct Point: Identifiable {
        let id: Int
        let series: HistorySeries
        let run: String
        let date: Date
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        var n = 0
        for s in series.sorted(by: { $0.drawOrder < $1.drawOrder }) {
            var run = 0
            var last: Date?
            var inRun = false
            for r in records {
                guard let d = r.date else { continue }
                guard let v = s.value(r) else { inRun = false; last = d; continue }
                if !inRun || (last.map { d.timeIntervalSince($0) > range.gapSeconds } ?? false) { run += 1 }
                inRun = true
                last = d
                out.append(Point(id: n, series: s, run: "\(s.id)-\(run)", date: d, value: min(100, max(0, v))))
                n += 1
            }
        }
        return out
    }

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
            ForEach(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("Usage", p.value), series: .value("Run", p.run))
                    .foregroundStyle(p.series.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: p.series.dashed ? [5, 4] : []))
                    .interpolationMethod(.linear)
            }
        }
        .chartXScale(domain: domain)
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
                    if let d = v.as(Date.self) { Text(range.tickLabel(d)).font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3) }
                }
            }
        }
        .chartLegend(.hidden)
        .padding(.trailing, 16)   // room for the last date label
        .chartOverlay { proxy in
            HoverLayer(proxy: proxy, records: records, series: series, gapSeconds: range.gapSeconds)
        }
    }
}

private struct HoverLayer: View {
    let proxy: ChartProxy
    let records: [HistoryRecordDTO]
    let series: [HistorySeries]
    let gapSeconds: Double
    @State private var hovered: HistoryRecordDTO?

    var body: some View {
        GeometryReader { geo in
            let plot = geo[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let t: Date = proxy.value(atX: loc.x - plot.minX),
                                  let r = HistoryRecordDTO.nearest(records, to: t),
                                  let d = r.date, abs(d.timeIntervalSince(t)) <= gapSeconds else { hovered = nil; return }
                            hovered = r
                        case .ended:
                            hovered = nil
                        }
                    }
                if let r = hovered, let d = r.date, let px = proxy.position(forX: d) {
                    let x = plot.minX + px
                    Path { p in p.move(to: CGPoint(x: x, y: plot.minY)); p.addLine(to: CGPoint(x: x, y: plot.maxY)) }
                        .stroke(Theme.ink3, lineWidth: 1)
                        .allowsHitTesting(false)
                    ForEach(series) { s in
                        if let v = s.value(r), let py = proxy.position(forY: min(100, max(0, v))) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                                .position(x: x, y: plot.minY + py)
                                .allowsHitTesting(false)
                        }
                    }
                    tooltip(r, d)
                        .fixedSize()
                        .alignmentGuide(.leading) { dim in
                            x + 14 + dim.width > plot.maxX ? -(x - 14 - dim.width) : -(x + 14)
                        }
                        .alignmentGuide(.top) { _ in -(plot.minY + 6) }
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(_ r: HistoryRecordDTO, _ d: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let flags = [r.stale == true ? "cached" : nil, r.error?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }
            Text(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
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
}

private struct LineSwatch: View {
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
    let value: (HistoryRecordDTO) -> Double?

    static func all(for records: [HistoryRecordDTO]) -> [HistorySeries] {
        var out = [
            HistorySeries(id: "weekly", label: "Weekly", color: Color(hex: 0x3987e5), dashed: false, drawOrder: 2) { $0.weekly?.pct },
            HistorySeries(id: "session", label: "Session (5h)", color: Color(hex: 0x199e70), dashed: false, drawOrder: 0) { $0.session?.pct },
        ]
        if let name = records.lazy.compactMap({ $0.models?.first?.name }).first {
            out.append(HistorySeries(id: "model", label: "\(name) weekly", color: Color(hex: 0xd95926), dashed: true, drawOrder: 1) { r in
                r.models?.first(where: { $0.name == name })?.pct
            })
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

    var date: Date? { TimeFmt.parse(ts) }

    /// The record nearest to `t` (records sorted by time).
    static func nearest(_ records: [HistoryRecordDTO], to t: Date) -> HistoryRecordDTO? {
        guard !records.isEmpty else { return nil }
        var lo = 0, hi = records.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if (records[mid].date ?? .distantPast) < t { lo = mid } else { hi = mid }
        }
        let dl = abs((records[lo].date ?? .distantPast).timeIntervalSince(t))
        let dh = abs((records[hi].date ?? .distantPast).timeIntervalSince(t))
        return dh < dl ? records[hi] : records[lo]
    }
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
