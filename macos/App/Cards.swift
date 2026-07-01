import SwiftUI

/// Stacked card for one account — used when the window is too narrow for the table.
struct AccountCard: View {
    let a: AccountDTO
    let now: Date
    var onRelogin: () -> Void
    var onRemove: () -> Void

    private var hasExtras: Bool {
        !(a.usage?.weeklyModels?.isEmpty ?? true) || (a.usage?.overage?.enabled == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(a.name).font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        if let t = a.tier {
                            Text(t).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hair, lineWidth: 1))
                        }
                        statusTag
                    }
                }
                Spacer()
                actions
            }
            cardMetric("Session · 5h", a.usage?.session, .session)
            cardMetric("Weekly", a.usage?.weekly, .weekly)
            if hasExtras {
                HStack(alignment: .top) {
                    ModelCell(usage: a.usage)
                    Spacer()
                    OverageCell(usage: a.usage)
                }
            }
        }
        .padding(16)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor, lineWidth: 1))
    }

    @ViewBuilder private var statusTag: some View {
        if a.isRelogin { tag("NEEDS RE-LOGIN", Theme.alarm) }
        else if a.stale == true { tag("CACHED", Theme.warn) }
        else if a.isErrored { tag("UNAVAILABLE", Theme.ink3) }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(Theme.mono(9.5, .medium)).foregroundColor(c).tracking(0.5)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if a.isRelogin {
                Button(action: onRelogin) { Text("Re-login").font(Theme.ui(11.5, .medium)) }
                    .buttonStyle(PillButton(color: Theme.alarm))
            }
            Button(action: onRemove) { Text("✕").font(Theme.ui(13)) }
                .buttonStyle(PillButton(color: Theme.ink3, subtle: true))
        }
    }

    private func cardMetric(_ label: String, _ w: WindowDTO?, _ kind: MetricKind) -> some View {
        let pct = w?.pct
        let sev = Severity.of(pct)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.mono(11, .regular)).foregroundColor(Theme.ink3).tracking(0.5)
                Spacer()
                if let pct = pct {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(pct))").font(Theme.mono(20, .semibold)).foregroundColor(sev.color)
                        Text("%").font(Theme.mono(12, .medium)).foregroundColor(sev == .idle ? Theme.ink4 : Theme.ink3)
                    }
                } else {
                    Text("—").font(Theme.mono(20, .semibold)).foregroundColor(Theme.ink4)
                }
            }
            Meter(pct: pct ?? 2, sev: pct == nil ? .idle : sev, maxW: .infinity)
            Text((pct ?? 0) > 0 ? TimeFmt.resetText(w?.resetsAt, now: now) : (kind == .session ? "idle" : "at rest"))
                .font(Theme.mono(10.5, .regular))
                .foregroundColor(sev == .alarm ? Color(hex: 0xcf9a9c) : Theme.ink4)
        }
        .opacity(a.isRelogin ? 0.4 : 1)
    }

    private var cardBg: Color {
        if a.usage != nil && a.worstPct >= Theme.critPct { return Theme.alarmBg }
        if a.isRelogin { return Theme.alarm.opacity(0.05) }
        return Theme.panel
    }
    private var borderColor: Color {
        if (a.usage != nil && a.worstPct >= Theme.critPct) || a.isRelogin { return Theme.alarm.opacity(0.45) }
        return Theme.hair
    }
}
