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
    /// Swipe right: mark read, or unread when it already is.
    @MainActor
    static func read(_ story: Story, isRead: Bool, model: AppModel) -> SwipeAction {
        SwipeAction(title: isRead ? "Unread" : "Read", spokenTitle: isRead ? "Mark as unread" : "Mark as read",
                    systemImage: isRead ? "envelope.badge" : "envelope.open", tint: .blue) {
            model.setRead(story, !isRead)
        }
    }

    /// Swipe left: save for later, or unsave when it already is.
    @MainActor
    static func save(_ story: Story, isSaved: Bool, model: AppModel) -> SwipeAction {
        SwipeAction(title: isSaved ? "Unsave" : "Save", spokenTitle: isSaved ? "Remove from Saved" : "Save for later",
                    systemImage: isSaved ? "bookmark.slash" : "bookmark", tint: .orange) {
            model.setSaved(story, !isSaved)
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
    /// A quick flick acts from this far, so a short fast swipe works too.
    static let flickDistance: CGFloat = 32
    /// Points per second that count as a flick.
    static let flickSpeed: CGFloat = 700
    /// A rightward swipe that starts this close to the screen's left edge is left to the system's
    /// swipe back to the previous page.
    static let edgeZone: CGFloat = 24
    /// A movement has to be this much more sideways than vertical to be a swipe rather than a scroll.
    static let sidewaysBias: CGFloat = 1.3

    enum Edge: Equatable, Sendable { case leading, trailing }

    static func isSideways(_ movement: CGSize) -> Bool {
        abs(movement.width) > abs(movement.height) * sidewaysBias
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
    /// Past the threshold always; a flick (`velocity` in points per second, same direction) from
    /// `flickDistance`.
    static func outcome(_ offset: CGFloat, velocity: CGFloat = 0) -> Edge? {
        let flicked = abs(velocity) >= flickSpeed && abs(offset) >= flickDistance && (velocity > 0) == (offset > 0)
        guard abs(offset) >= threshold || flicked, offset != 0 else { return nil }
        return offset > 0 ? .leading : .trailing
    }
}

/// Swipe a story row to act on it in one motion: right marks it read, left saves it. Past the
/// threshold the action's colour fills in and the phone ticks; letting go does it, with no button
/// to tap afterwards (a quick flick works too). Short of it the row slides back.
///
/// The swipe is a UIKit pan, like Mail's rows: it only starts for a sideways movement, and the list
/// waits for it to be ruled out before scrolling, so vertical scrolling is never blocked or slowed.
/// (A SwiftUI drag on every row blocked scrolling and redrew the row on every frame of a scroll.)
/// Rows open with a tap gesture, which a swipe cancels, so a swipe never also opens the story.
/// iOS 17, which has no UIKit gestures in SwiftUI, gets the system swipe actions with full swipe.
struct StorySwipe: ViewModifier {
    /// Swipe right.
    let leading: SwipeAction?
    /// Swipe left.
    let trailing: SwipeAction?
    /// The row's own background, which slides with it so the action shows only where it left.
    let rowBackground: Color
    /// Rows inside a grouped list's margins round and clip the swipe; edge-to-edge rows don't clip.
    let cornerRadius: CGFloat

    @State private var offset: CGFloat = 0
    @State private var armed: SwipeRule.Edge?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            sliding(content)
                .gesture(SwipePan(canLead: leading != nil, canTrail: trailing != nil,
                                  onChange: track, onEnd: finish, onCancel: settle))
        } else {
            content
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if let leading { systemButton(leading) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if let trailing { systemButton(trailing) }
                }
        }
    }

    @ViewBuilder
    private func sliding(_ content: Content) -> some View {
        let moved = content
            .background(offset == 0 ? Color.clear : rowBackground)
            .offset(x: offset)
            .background { reveal }
        if cornerRadius > 0 {
            moved.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            moved
        }
    }

    private func track(_ dx: CGFloat) {
        offset = SwipeRule.offset(dx, canLead: leading != nil, canTrail: trailing != nil)
        let now = SwipeRule.outcome(offset)
        guard now != armed else { return }
        if now != nil { SwipeHaptics.tick() }
        armed = now
    }

    /// Decided from the gesture's own final numbers, not from view state, which may already have
    /// been reset by the time the gesture reports its end.
    private func finish(_ dx: CGFloat, _ velocity: CGFloat) {
        let shown = SwipeRule.offset(dx, canLead: leading != nil, canTrail: trailing != nil)
        switch SwipeRule.outcome(shown, velocity: velocity) {
        case .leading?: leading?.perform()
        case .trailing?: trailing?.perform()
        case nil: break
        }
        settle()
    }

    private func settle() {
        armed = nil
        guard offset != 0 else { return }
        withAnimation(.snappy(duration: 0.25)) { offset = 0 }
    }

    @ViewBuilder
    private var reveal: some View {
        if offset > 0, let leading {
            SwipeReveal(action: leading, edge: .leading, armed: armed == .leading)
        } else if offset < 0, let trailing {
            SwipeReveal(action: trailing, edge: .trailing, armed: armed == .trailing)
        }
    }

    private func systemButton(_ action: SwipeAction) -> some View {
        Button { action.perform() } label: { Label(action.title, systemImage: action.systemImage) }
            .tint(action.tint)
    }
}

/// The sideways pan behind StorySwipe. It begins only for a mostly sideways movement (never from
/// the screen's left edge, which belongs to the back swipe), and the list's scrolling waits for it
/// to fail first, the way UITableView's swipe actions work.
@available(iOS 18.0, *)
private struct SwipePan: UIGestureRecognizerRepresentable {
    let canLead: Bool
    let canTrail: Bool
    let onChange: @MainActor (CGFloat) -> Void
    /// Final translation and velocity, in points and points per second.
    let onEnd: @MainActor (CGFloat, CGFloat) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        context.coordinator.canLead = canLead
        context.coordinator.canTrail = canTrail
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.canLead = canLead
        context.coordinator.canTrail = canTrail
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChange(dx)
        case .ended: onEnd(dx, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: onCancel()
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canLead = true
        var canTrail = true

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            let moved = pan.translation(in: pan.view)
            // Velocity says where the finger is heading; a very slow drag falls back to how far it went.
            let direction = hypot(velocity.x, velocity.y) > 50 ? velocity : moved
            guard SwipeRule.isSideways(CGSize(width: direction.x, height: direction.y)) else { return false }
            if direction.x > 0 {
                let startX = pan.location(in: nil).x - pan.translation(in: nil).x
                return canLead && startX > SwipeRule.edgeZone
            }
            return canTrail
        }

        /// The list's scrolling waits until this swipe is ruled out (at the first movement).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// The tick when a swipe reaches the point where letting go acts. One generator for every row.
@MainActor
private enum SwipeHaptics {
    static let generator = UIImpactFeedbackGenerator(style: .medium)
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
    /// One-motion swipes on a story row (see StorySwipe).
    func storySwipe(leading: SwipeAction?, trailing: SwipeAction?, rowBackground: Color,
                    cornerRadius: CGFloat = 0) -> some View {
        modifier(StorySwipe(leading: leading, trailing: trailing, rowBackground: rowBackground,
                            cornerRadius: cornerRadius))
    }

    /// The swipes as named VoiceOver actions. Apply to the row's accessibility element itself.
    func swipeAccessibilityActions(_ leading: SwipeAction?, _ trailing: SwipeAction?) -> some View {
        accessibilityActions {
            if let leading { Button(leading.spokenTitle) { leading.perform() } }
            if let trailing { Button(trailing.spokenTitle) { trailing.perform() } }
        }
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
