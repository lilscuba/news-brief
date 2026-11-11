import SwiftUI
import UIKit

// MARK: - One-motion swipes

/// What a swipe on a story row does.
struct SwipeAction {
    /// Shown behind the row while swiping.
    let title: String
    /// The VoiceOver action's name.
    let spokenTitle: String
    let systemImage: String
    let tint: Color
    let perform: () -> Void
}

extension SwipeAction {
    /// Swipe right: mark read, or unread when it already is. `isRead` words the action; what it
    /// does is decided when it runs, so an action made before the row last changed still toggles.
    @MainActor
    static func read(_ story: Story, isRead: Bool, model: AppModel) -> SwipeAction {
        SwipeAction(title: isRead ? "Unread" : "Read", spokenTitle: isRead ? "Mark as unread" : "Mark as read",
                    systemImage: isRead ? "envelope.badge" : "envelope.open", tint: .blue) {
            model.toggleRead(story)
        }
    }

    /// Swipe left: save for later, or unsave when it already is (decided when it runs, as above).
    @MainActor
    static func save(_ story: Story, isSaved: Bool, model: AppModel) -> SwipeAction {
        SwipeAction(title: isSaved ? "Unsave" : "Save", spokenTitle: isSaved ? "Remove from Saved" : "Save for later",
                    systemImage: isSaved ? "bookmark.slash" : "bookmark", tint: .orange) {
            model.toggleSaved(story)
        }
    }

    /// Swipe left in Saved: take it off the list.
    @MainActor
    static func removeSaved(_ story: Story, model: AppModel) -> SwipeAction {
        SwipeAction(title: "Remove", spokenTitle: "Remove from Saved", systemImage: "bookmark.slash", tint: .red) {
            model.setSaved(story, false)
        }
    }
}

/// The rules of a story-row swipe, kept apart from the view so they can be tested.
enum SwipeRule {
    /// How far a row has to be dragged for letting go to act.
    static let threshold: CGFloat = 80
    /// A rightward drag that starts this close to the screen's left edge is left to the system's
    /// swipe back to the previous page.
    static let edgeZone: CGFloat = 24
    /// The first movement has to be this much more sideways than vertical to be a swipe rather
    /// than a scroll.
    static let sidewaysBias: CGFloat = 1.3
    /// @AppStorage key for "Swipe in one motion" (Settings > Reading, default on). Off, rows get
    /// the system's swipe buttons instead.
    static let oneMotionKey = "oneMotionSwipes"
    /// One-motion swipes need gesture recognizers in SwiftUI, which iOS 18 added.
    static var oneMotionAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    enum Edge: Equatable, Sendable { case leading, trailing }

    static func isSideways(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * sidewaysBias
    }

    /// Whether a drag is a swipe on this row at all. `movement` is the direction it set off in and
    /// `startX` where it started, from the screen's left edge. Anything else (a scroll, the swipe
    /// back, a side with no action) is never taken, so the list and the system keep it.
    static func begins(movement: CGSize, startX: CGFloat, canLead: Bool, canTrail: Bool) -> Bool {
        guard isSideways(movement) else { return false }
        if movement.width > 0 { return canLead && startX >= edgeZone }
        return canTrail
    }

    /// Where a row dragged by `dx` is drawn: with the finger up to 1.6 times the threshold, then
    /// stiffer. A side with no action doesn't move.
    static func offset(_ dx: CGFloat, canLead: Bool, canTrail: Bool) -> CGFloat {
        if (dx > 0 && !canLead) || (dx < 0 && !canTrail) { return 0 }
        let limit = threshold * 1.6
        let distance = abs(dx)
        let shown = distance <= limit ? distance : limit + (distance - limit) * 0.3
        return dx < 0 ? -shown : shown
    }

    /// The action letting go at `offset` performs: leading for a swipe right, trailing for left.
    static func outcome(_ offset: CGFloat) -> Edge? {
        if offset >= threshold { return .leading }
        if offset <= -threshold { return .trailing }
        return nil
    }
}

/// Swipe a story row to act on it in one motion: right marks it read, left saves it. Past the
/// threshold the action's colour fills in and the phone ticks; letting go does it, with no button
/// to tap afterwards. Short of the threshold the row just slides back.
///
/// The swipe is a UIKit pan recognizer that refuses to begin unless the finger sets off sideways
/// (`SwipeRule.begins`), so a vertical drag is never taken from the list: it scrolls exactly as it
/// would with no swipe on the row. The action runs when the recognizer reports the finger lifted.
/// (A SwiftUI DragGesture was here first. It recognized drags in every direction, and on the phone
/// the list would not scroll and a swipe slid back without acting.)
///
/// Before iOS 18 (which added recognizers to SwiftUI), or with "Swipe in one motion" off, rows get
/// the system's swipe buttons; a full swipe still acts without a tap.
struct StorySwipe: ViewModifier {
    /// Swipe right.
    let leading: SwipeAction?
    /// Swipe left.
    let trailing: SwipeAction?
    /// The row's own background, which slides with it so the action shows only where it left.
    let rowBackground: Color
    /// Rows inside a grouped list's margins round the swipe's edges; edge-to-edge rows don't.
    let cornerRadius: CGFloat

    @Environment(\.oneMotionSwipes) private var oneMotion
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), oneMotion {
            sliding(content)
        } else {
            content
                .swipeActions(edge: .leading) { button(leading) }
                .swipeActions(edge: .trailing) { button(trailing) }
        }
    }

    @available(iOS 18.0, *)
    @MainActor
    private func sliding(_ content: Content) -> some View {
        let armed = SwipeRule.outcome(offset)
        return content
            .background(offset == 0 ? Color.clear : rowBackground)
            .offset(x: offset)
            .background { reveal(armed: armed) }
            // The row slides inside its own frame, never over the list's margins.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .gesture(SidewaysPan(canLead: leading != nil, canTrail: trailing != nil,
                                 moved: { dragged(to: $0) }, finished: { released(completed: $0) }))
    }

    /// The finger is `dx` from where the swipe began.
    @MainActor
    private func dragged(to dx: CGFloat) {
        let before = SwipeRule.outcome(offset)
        offset = SwipeRule.offset(dx, canLead: leading != nil, canTrail: trailing != nil)
        // One tick as the row crosses the point where letting go will act.
        if let now = SwipeRule.outcome(offset), now != before { SwipeHaptics.tick() }
    }

    /// The finger lifted (`completed`), or the system took the touch away: only a lift acts.
    @MainActor
    private func released(completed: Bool) {
        if completed {
            switch SwipeRule.outcome(offset) {
            case .leading?: leading?.perform()
            case .trailing?: trailing?.perform()
            case nil: break
            }
        }
        guard offset != 0 else { return }
        withAnimation(.snappy(duration: 0.25)) { offset = 0 }
    }

    @ViewBuilder
    private func reveal(armed: SwipeRule.Edge?) -> some View {
        if offset > 0, let leading {
            SwipeReveal(action: leading, edge: .leading, armed: armed == .leading)
        } else if offset < 0, let trailing {
            SwipeReveal(action: trailing, edge: .trailing, armed: armed == .trailing)
        }
    }

    /// The system's swipe button for an action.
    @ViewBuilder
    private func button(_ action: SwipeAction?) -> some View {
        if let action {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.systemImage)
            }
            .tint(action.tint)
        }
    }
}

/// A pan that only begins for a sideways drag on a row with an action on that side. UIKit asks
/// before the pan starts; answering no leaves the touch with the list (and with the swipe back),
/// which is what keeps scrolling untouched.
@available(iOS 18.0, *)
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let canLead: Bool
    let canTrail: Bool
    /// How far the finger is from where the pan began, sideways.
    let moved: (CGFloat) -> Void
    /// True when the finger lifted, false when the touch was taken away.
    let finished: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        configure(context.coordinator)
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // The row's actions change with its state (Read becomes Unread): always the latest.
        configure(context.coordinator)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began, .changed: coordinator.moved(recognizer.translation(in: recognizer.view).x)
        case .ended: coordinator.finished(true)
        case .cancelled, .failed: coordinator.finished(false)
        default: break
        }
    }

    private func configure(_ coordinator: Coordinator) {
        coordinator.canLead = canLead
        coordinator.canTrail = canTrail
        coordinator.moved = moved
        coordinator.finished = finished
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canLead = false
        var canTrail = false
        var moved: (CGFloat) -> Void = { _ in }
        var finished: (Bool) -> Void = { _ in }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let travelled = pan.translation(in: nil)
            // The direction it set off in: its velocity, or how far it has come when that's still zero.
            let movement = velocity == .zero ? CGSize(width: travelled.x, height: travelled.y)
                                             : CGSize(width: velocity.x, height: velocity.y)
            let startX = pan.location(in: nil).x - travelled.x
            return SwipeRule.begins(movement: movement, startX: startX, canLead: canLead, canTrail: canTrail)
        }
    }
}

/// The tick when a swipe reaches the point where letting go will act. One generator for every
/// row, rather than one per row.
@MainActor
private enum SwipeHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .medium)

    static func tick() { generator.impactOccurred() }
}

/// The colour and icon behind a row being swiped: faint until letting go would act, then full.
private struct SwipeReveal: View {
    let action: SwipeAction
    let edge: SwipeRule.Edge
    let armed: Bool

    var body: some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            Rectangle()
                .fill(action.tint.opacity(armed ? 1 : 0.5))
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.title3.weight(.semibold))
                Text(action.title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .scaleEffect(armed ? 1.1 : 0.85)
            .padding(.horizontal, 22)
        }
        .animation(.snappy(duration: 0.2), value: armed)
        .accessibilityHidden(true)
    }
}

extension View {
    /// One-motion swipes on a story row (see StorySwipe). The row becomes one VoiceOver element,
    /// with the swipes as its actions.
    func storySwipe(leading: SwipeAction?, trailing: SwipeAction?, rowBackground: Color,
                    cornerRadius: CGFloat = 0) -> some View {
        modifier(StorySwipe(leading: leading, trailing: trailing, rowBackground: rowBackground,
                            cornerRadius: cornerRadius))
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if let leading { Button(leading.spokenTitle) { leading.perform() } }
                if let trailing { Button(trailing.spokenTitle) { trailing.perform() } }
            }
    }
}

// MARK: - One motion or buttons

private struct OneMotionSwipesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// "Swipe in one motion" (Settings > Reading). Read once at the root and handed down, rather
    /// than every row watching the setting itself.
    var oneMotionSwipes: Bool {
        get { self[OneMotionSwipesKey.self] }
        set { self[OneMotionSwipesKey.self] = newValue }
    }
}

// MARK: - Which stack a row is in

private struct NavigationTabKey: EnvironmentKey {
    static let defaultValue: AppTab = .today
}

extension EnvironmentValues {
    /// The tab whose navigation stack a view is in, so a tapped story row opens its page there.
    var navigationTab: AppTab {
        get { self[NavigationTabKey.self] }
        set { self[NavigationTabKey.self] = newValue }
    }
}

// MARK: - The swipe-to-save tip

/// "Swipe left to save", over the top of the screen after an article closes. Tucks itself away
/// after a few seconds (not while VoiceOver is on); the model keeps it asleep for 30 minutes after.
struct SwipeTipCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prompt: SwipeTipPrompt

    var body: some View {
        let saved = model.isSaved(prompt.story)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                hint
                VStack(alignment: .leading, spacing: 3) {
                    Text("Swipe left to save")
                        .font(.headline)
                    Text("Swipe left on any story to keep it in Saved. Stories you've read stay in the list for 10 minutes, so there's time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    model.dismissSwipeTip()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tip")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons(saved: saved) }
                VStack(alignment: .leading, spacing: 8) { buttons(saved: saved) }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .task(id: prompt.id) {
            AccessibilityNotification.Announcement("Tip: swipe left on a story to save it.").post()
            guard !voiceOver else { return }
            try? await Task.sleep(for: SwipeTip.visibleFor)
            guard !Task.isCancelled, model.swipeTip?.id == prompt.id else { return }
            withAnimation(.snappy) { model.dismissSwipeTip() }
        }
    }

    @ViewBuilder
    private func buttons(saved: Bool) -> some View {
        Button {
            model.setSaved(prompt.story, true)
            model.dismissSwipeTip()
        } label: {
            Label(saved ? "Saved" : "Save This Story", systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(saved)
        Button("Don't Show Again") { model.dismissSwipeTip(forever: true) }
            .buttonStyle(.bordered)
            .accessibilityHint("You can turn the tip back on in Settings")
    }

    /// A bookmark that nudges left, the way the gesture goes.
    private var hint: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .phaseAnimator(reduceMotion ? [CGFloat(0)] : [CGFloat(0), -7]) { view, x in
                view.offset(x: x)
            } animation: { _ in .easeInOut(duration: 0.45) }
            .accessibilityHidden(true)
    }
}
