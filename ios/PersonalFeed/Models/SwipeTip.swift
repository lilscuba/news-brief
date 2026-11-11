import Foundation

/// The "swipe left to save" tip shown when the reader closes an article. After each showing it
/// sleeps for 30 minutes; "Don't show again" turns it off for good (Settings > Reading turns it
/// back on).
enum SwipeTip {
    static let snooze: TimeInterval = 30 * 60
    /// UserDefaults keys; Settings reads `disabledKey` with @AppStorage.
    static let disabledKey = "swipeTipDisabled"
    static let shownAtKey = "swipeTipShownAt"
    /// Seconds on screen before it tucks itself away (not while VoiceOver is on).
    static let visibleFor: Duration = .seconds(10)

    /// True when the tip may show now.
    static func isDue(now: Date, lastShown: Date?, disabled: Bool) -> Bool {
        guard !disabled else { return false }
        guard let lastShown else { return true }
        // abs: a clock set back by hours shouldn't keep it asleep until the clock catches up.
        return abs(now.timeIntervalSince(lastShown)) >= snooze
    }
}

/// The tip on screen, for the story whose article was just closed (its "Save It" button).
struct SwipeTipPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let story: Story
}
