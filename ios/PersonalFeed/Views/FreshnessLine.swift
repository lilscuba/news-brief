import SwiftUI

/// What the line under Today's date says about how current the news is.
struct Freshness: Equatable {
    enum Tone: Equatable {
        /// "Updated 12 minutes ago"
        case normal
        /// "Checking for news…"
        case checking
        /// The server's updates are late.
        case stale
        /// The phone couldn't check (offline, server error).
        case problem
    }

    let text: String
    let systemImage: String?
    let tone: Tone

    /// The feed is rebuilt every 10-15 minutes, so two hours without one means the server's
    /// updates are late, not that the news is quiet.
    static let staleAfter: TimeInterval = 2 * 3600

    /// Today's brief. `generatedAt` is when the server last built the news, `checkedAt` when the
    /// phone last heard back.
    static func live(generatedAt: Date, checkedAt: Date?, status: FeedStatus?, isChecking: Bool,
                     now: Date) -> Freshness {
        let age = ago(generatedAt, now: now)
        if isChecking {
            return Freshness(text: "Checking for news…", systemImage: nil, tone: .checking)
        }
        if let status {
            return Freshness(text: "\(status.message) · showing news from \(age)",
                             systemImage: status.systemImage, tone: .problem)
        }
        if now.timeIntervalSince(generatedAt) > staleAfter {
            // Says the server is behind, not the reader's connection: the phone did check.
            let checked = checkedAt.map { " · checked \(ago($0, now: now))" } ?? ""
            return Freshness(text: "News last updated \(age)\(checked)",
                             systemImage: "clock.badge.exclamationmark", tone: .stale)
        }
        return Freshness(text: "Updated \(age)", systemImage: nil, tone: .normal)
    }

    /// A past brief: when it was last updated, never "stale".
    static func snapshot(generatedAt: Date) -> Freshness {
        Freshness(text: "Last updated \(generatedAt.formatted(date: .omitted, time: .shortened))",
                  systemImage: "clock", tone: .normal)
    }

    /// "just now", "12 minutes ago", "3 hours ago". A time in the future (clock skew) is just now.
    static func ago(_ date: Date, now: Date) -> String {
        RelativeAge.spoken(date, now: now)
    }

    /// "14 new since 9:40 AM", "3 new since yesterday 9:40 PM", "8 new since Sat 9:40 PM".
    static func newSince(count: Int, since: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = since.formatted(date: .omitted, time: .shortened)
        let when: String
        if calendar.isDate(since, inSameDayAs: now) {
            when = time
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(since, inSameDayAs: yesterday) {
            when = "yesterday \(time)"
        } else {
            when = since.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return "\(count) new since \(when)"
    }
}

/// The freshness line on Today (and a quieter "Last updated" on past briefs). Its list's
/// `minuteClock()` re-renders it every minute, so "Updated 2 minutes ago" doesn't freeze while the
/// app stays open. (A TimelineView of its own inside the List row kept the main thread busy
/// re-laying out the list every frame.)
struct FreshnessLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.listClock) private var clock
    let brief: Brief
    let isLive: Bool
    /// Quick automatic checks (a 304 takes a fraction of a second) shouldn't flash the line.
    @State private var showsChecking = false

    var body: some View {
        let freshness = isLive
            ? Freshness.live(generatedAt: brief.generatedAt, checkedAt: model.lastCheckedAt,
                             status: model.feedStatus, isChecking: showsChecking, now: clock ?? .now)
            : Freshness.snapshot(generatedAt: brief.generatedAt)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch freshness.tone {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
            case .stale:
                Image(systemName: freshness.systemImage ?? "clock")
                    .foregroundStyle(.orange)
            case .problem:
                Image(systemName: freshness.systemImage ?? "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            case .normal:
                EmptyView()
            }
            Text(freshness.text)
                // Orange text on white is hard to read; the icon carries the colour.
                .foregroundStyle(freshness.tone == .stale || freshness.tone == .problem
                                 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .task(id: isLive && model.isRefreshing) {
            guard isLive && model.isRefreshing else { showsChecking = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { showsChecking = true }
        }
    }
}

/// A short message in a capsule over the bottom of a list, optionally with an action (Undo).
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (l: Toast, r: Toast) -> Bool { l.id == r.id }

    /// Pull to refresh anywhere on Today's stack: checks for news, shows an automatic update that
    /// was held while the reader was scrolled down (even when the server has nothing newer, a
    /// 304), and says what happened.
    @MainActor
    static func pullToRefresh(_ model: AppModel) async -> Toast {
        // Counted against what the reader was looking at, so a held update's stories count too.
        let shown = Set(model.brief?.allStories.map(\.id) ?? [])
        let held = model.pendingBrief != nil
        var outcome = await model.refresh(reason: .user)
        if model.pendingBrief != nil { model.applyPendingBrief() }
        if outcome != .failed, held || outcome != .unchanged {
            let added = Set(model.brief?.allStories.map(\.id) ?? []).subtracting(shown).count
            outcome = .updated(newCount: added)
        }
        return refreshed(outcome, status: model.feedStatus)
    }

    /// What pull-to-refresh found, so "nothing new" doesn't look like nothing happened.
    static func refreshed(_ outcome: RefreshOutcome, status: FeedStatus?) -> Toast {
        switch outcome {
        case .updated(let count):
            return Toast(message: count == 0 ? "Brief updated"
                                             : "\(count) new \(count == 1 ? "story" : "stories")",
                         systemImage: "sparkles")
        case .unchanged:
            return Toast(message: "You're up to date", systemImage: "checkmark.circle")
        case .failed:
            return Toast(message: status?.message ?? "Couldn't check for news", systemImage: status?.systemImage ?? "wifi.slash")
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(toast.message, systemImage: toast.systemImage ?? "info.circle")
                .font(.subheadline.weight(.medium))
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

extension View {
    /// Shows `toast` at the top of the view, under the navigation bar, for a few seconds (longer
    /// when it has an action) and reads it out for VoiceOver. Not at the bottom: since iOS 26 the
    /// floating tab bar isn't part of the safe area there, so a bottom toast slid under it.
    func toast(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .top) {
            if let current = toast.wrappedValue {
                ToastView(toast: current) { toast.wrappedValue = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: current.id) {
                        AccessibilityNotification.Announcement(current.message).post()
                        try? await Task.sleep(for: .seconds(current.action == nil ? 2.5 : 5))
                        if toast.wrappedValue?.id == current.id { toast.wrappedValue = nil }
                    }
            }
        }
        .animation(.snappy, value: toast.wrappedValue)
    }
}
