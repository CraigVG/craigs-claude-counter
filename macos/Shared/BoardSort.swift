import Foundation

/// Board ordering: weekly reset by default (soonest on top), or a column.
/// Mirrors src/board.mjs so the app and the web board agree: a first click sorts
/// usage columns lowest first and plan / overage largest first, a second click
/// reverses, a third returns to weekly reset. Accounts with no data for the column
/// sink to the bottom in either direction. Reset ties preserve input order;
/// other column ties fall back to headroom, then name.
enum SortColumn: String, CaseIterable {
    case reset, headroom, account, plan, session, weekly, model, overage

    var label: String {
        switch self {
        case .reset: return "weekly reset"
        case .model: return "model weekly"
        default: return rawValue
        }
    }

    var help: String {
        switch self {
        case .reset: return "Sort by weekly reset date"
        case .headroom: return "Sort by headroom"
        case .account: return "Sort by account name"
        case .plan: return "Sort by plan (weekly capacity)"
        case .session: return "Sort by session usage"
        case .weekly: return "Sort by weekly usage"
        case .model: return "Sort by per-model weekly usage"
        case .overage: return "Sort by overage spent"
        }
    }

    var firstAscending: Bool { !(self == .plan || self == .overage) }

    /// The numeric sort value, nil when the account has no data for the column.
    /// `.account` sorts by name and `.headroom` by `sortKey` instead.
    func value(_ a: AccountDTO) -> Double? {
        switch self {
        case .reset: return TimeFmt.parse(a.usage?.weekly?.resetsAt)?.timeIntervalSince1970
        case .headroom, .account: return nil
        case .plan: return a.tier.map(Self.planWeight)
        case .session: return a.usage.map { $0.session?.pct ?? 0 }
        case .weekly: return a.usage?.weekly?.pct
        case .model: return (a.usage?.weeklyModels ?? []).compactMap(\.pct).max()
        case .overage:
            guard let o = a.usage?.overage, o.enabled == true else { return nil }
            return o.usedUsd
        }
    }

    /// Weekly capacity relative to Pro, as the fleet weights it (src/fleet.mjs tierWeight).
    static func planWeight(_ tier: String) -> Double {
        let t = tier.lowercased()
        if t.contains("20x") { return 7 }
        if t.contains("5x") || t.contains("max") || t.contains("team") { return 3.5 }
        if t.contains("pro") { return 1 }
        return 3.5
    }
}

struct BoardSort: Equatable {
    var column: SortColumn = .reset
    var ascending = true

    static let storageKey = "boardSort"
    static let defaultSort = BoardSort()
    static let headroom = BoardSort(column: .headroom)

    init(column: SortColumn = .reset, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    /// Parses a stored "weekly:desc"; anything unrecognized is weekly reset.
    init(raw: String) {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let c = SortColumn(rawValue: parts[0]),
              parts[1] == "asc" || parts[1] == "desc" else { self = .defaultSort; return }
        self.init(column: c, ascending: parts[1] == "asc")
    }

    var raw: String { "\(column.rawValue):\(ascending ? "asc" : "desc")" }

    var note: String {
        switch column {
        case .reset: return "sorted by weekly reset · \(ascending ? "soonest" : "latest") first"
        case .headroom: return "sorted by headroom · most available on top"
        case .account: return "sorted by account · \(ascending ? "A–Z" : "Z–A")"
        default: return "sorted by \(column.label) · \(ascending ? "lowest" : "highest") first"
        }
    }

    /// The sort after a click on column `c`.
    func next(tapping c: SortColumn) -> BoardSort {
        guard c != .headroom else { return .headroom }
        if column != c { return BoardSort(column: c, ascending: c.firstAscending) }
        if ascending == c.firstAscending { return BoardSort(column: c, ascending: !ascending) }
        return .defaultSort
    }

    func sorted(_ accounts: [AccountDTO]) -> [AccountDTO] {
        accounts.sorted { a, b in
            switch column {
            case .headroom:
                break
            case .account:
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
            default:
                let va = column.value(a), vb = column.value(b)
                switch (va, vb) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
            }
            if column == .reset { return false }
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
