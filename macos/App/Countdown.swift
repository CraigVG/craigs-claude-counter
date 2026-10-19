import SwiftUI

/// A timeline that fires only when a `TimeFmt.short` countdown to `target` can
/// change its text: on each whole hour before the target while it reads in
/// days ("1d 4h"), on each whole minute under a day ("3h 12m", "8m"), and once
/// at the target ("now"). No entries after that, and none without a target.
struct CountdownSchedule: TimelineSchedule {
    let target: Date?

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = start
        return AnyIterator {
            guard let cur = next else { return nil }
            next = target.flatMap { Self.change(after: cur, target: $0) }
            return cur
        }
    }

    /// The first moment after `date` at which the countdown text differs.
    /// `short` truncates the remaining seconds, so the text for "q units left"
    /// holds until less than q units remain, and "0m" turns into "now" once
    /// less than a second remains. A small margin keeps the redraw on the far
    /// side of each boundary.
    static func change(after date: Date, target: Date) -> Date? {
        let r = target.timeIntervalSince(date)
        if r < 1 { return nil }
        let unit: Double = r >= 86400 ? 3600 : 60
        let q = (r / unit).rounded(.down)
        return target.addingTimeInterval(-(q > 0 ? q * unit : 1) + 0.05)
    }
}

/// Redraws `content` only when a countdown to `target` changes, so a ticking
/// reset label does not make its row, the board or the window re-evaluate.
struct Countdown<Content: View>: View {
    let target: Date?
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(CountdownSchedule(target: target)) { ctx in content(ctx.date) }
    }
}
