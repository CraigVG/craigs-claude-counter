import Foundation
import SwiftUI

// MARK: - DTOs matching the local engine's GET /api/usage response

struct UsageSnapshot: Decodable {
    var generatedAt: String?
    var accounts: [AccountDTO]
    /// Every account folded into one capacity-weighted picture (engine: src/fleet.mjs).
    var fleet: FleetDTO?
}

// MARK: - Fleet (GET /api/usage .fleet)

struct FleetDTO: Decodable {
    struct Accounts: Decodable {
        var total: Int
        var counted: Int
        var unknown: Int
        var blocked: Int
        var weightsAssumed: Int?
    }
    struct Event: Decodable {
        var at: String
        var inMs: Double
        var kind: String
        var account: String
        var restoresPct: Double
    }
    struct Pace: Decodable {
        struct Exhausting: Decodable { var account: String }
        var ratio: Double?
        var accounts: Int
        var exhausting: [Exhausting]
    }
    var accounts: Accounts
    var usedPct: Double?
    var freePct: Double?
    var backSoonPct: Double?
    var lockedPct: Double?
    var severity: String?
    var soonMs: Double?
    var events: [Event]
    var nextEvent: Event?
    var nextWeekly: Event?
    var freshBy: String?
    var pace: Pace

    var tone: Severity {
        switch severity { case "critical": return .alarm; case "warning": return .warn; default: return .normal }
    }
    var fillColor: Color {
        switch tone { case .alarm: return Theme.alarm; case .warn: return Theme.warn; default: return Theme.calm }
    }
    var soonHours: Int { Int(((soonMs ?? 18_000_000) / 3_600_000).rounded()) }
    /// Where usage would sit if the fleet were exactly on pace (the tick on the bar).
    var onPacePct: Double? {
        guard let r = pace.ratio, r > 0, let u = usedPct else { return nil }
        return min(100, max(0, u / r))
    }
}

struct AccountDTO: Decodable, Identifiable {
    var id: String
    var label: String?
    var tier: String?
    var usage: UsageDTO?
    var error: String?
    var message: String?
    var stale: Bool?
    var status: Int?

    var name: String { label ?? id }
    var isRelogin: Bool { error == "needs_relogin" }
    var isErrored: Bool { error != nil && error != "needs_relogin" }
    var worstPct: Double {
        guard let u = usage else { return 0 }
        return max(u.session?.pct ?? 0, u.weekly?.pct ?? 0)
    }
    // Tiered: at-limit > needs-relogin > warning > usage > idle  (matches the web app).
    // The app and web boards sort ascending (most available on top); the widget
    // sorts descending because it only has room for the most-constrained few.
    var sortKey: Double {
        let w = worstPct
        var tier = 0.0
        if usage != nil && w >= Theme.critPct { tier = 3 }
        else if isRelogin { tier = 2 }
        else if usage != nil && w >= Theme.warnPct { tier = 1 }
        return tier * 1000 + w
    }
}

struct UsageDTO: Decodable {
    var session: WindowDTO?
    var weekly: WindowDTO?
    // Per-model weekly sub-limits, in the order the API reports them. The set of
    // models is not fixed (was Opus/Sonnet, now Fable), so we render whatever
    // the engine surfaces rather than hardcoding names.
    var weeklyModels: [ModelLimitDTO]?
    var overage: OverageDTO?
}

struct WindowDTO: Decodable {
    var pct: Double?
    var resetsAt: String?
    var severity: String?
    var active: Bool?
}

struct ModelLimitDTO: Decodable {
    var name: String
    var pct: Double?
    var resetsAt: String?
    var severity: String?
    var active: Bool?
}

struct OverageDTO: Decodable {
    var usedUsd: Double
    var limitUsd: Double
    var pct: Double?
    var currency: String?
    var enabled: Bool?
}

// MARK: - Severity

enum Severity {
    case idle, normal, warn, alarm
    static func of(_ pct: Double?) -> Severity {
        guard let p = pct else { return .idle }
        if p >= Theme.critPct { return .alarm }
        if p >= Theme.warnPct { return .warn }
        if p <= 0 { return .idle }
        return .normal
    }
    var color: Color {
        switch self {
        case .alarm: return Theme.alarm
        case .warn:  return Theme.warn
        case .idle:  return Theme.ink4
        case .normal: return Theme.ink
        }
    }
    var meterColor: Color {
        switch self {
        case .alarm: return Theme.alarm
        case .warn:  return Theme.warn
        case .idle:  return Theme.calmDim
        case .normal: return Theme.calm
        }
    }
}

// MARK: - Time helpers

enum TimeFmt {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// "1d 4h" / "3h 12m" / "8m" — short duration until `date`.
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "in 3h 12m" / "now" — countdown to an event.
    static func inText(_ iso: String?, now: Date = Date()) -> String {
        let t = short(parse(iso), now: now)
        if t == "now" { return "now" }
        return t.isEmpty ? "" : "in \(t)"
    }

    /// "Wed, Sep 16 5:00 AM" for a far-off moment.
    static func dayClock(_ iso: String?) -> String {
        guard let d = parse(iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d h:mm a"
        return f.string(from: d)
    }

    static func resetText(_ iso: String?, now: Date = Date()) -> String {
        let t = short(parse(iso), now: now)
        if t == "now" { return "resetting…" }
        return t.isEmpty ? "" : "resets in \(t)"
    }
}

func usd(_ n: Double, fraction: Bool = true) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = fraction ? 2 : 0
    f.minimumFractionDigits = fraction ? 2 : 0
    return f.string(from: NSNumber(value: n)) ?? "$\(n)"
}
