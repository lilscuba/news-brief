import SwiftUI

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
    /// A rightward drag that starts this close to the row's leading edge is left to the system's
    /// swipe back to the previous page.
    static let edgeZone: CGFloat = 20
    /// The first movement has to be this much more sideways than vertical to be a swipe rather
    /// than a scroll.
    static let sidewaysBias: CGFloat = 1.3

    enum Edge: Equatable, Sendable { case leading, trailing }

    static func isSideways(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * sidewaysBias
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
/// A sideways drag never opens the story: rows open with a tap gesture, which a drag cancels.
/// Vertical drags are scrolls and leave the row alone.
struct StorySwipe: ViewModifier {
    /// Swipe right.
    let leading: SwipeAction?
    /// Swipe left.
    let trailing: SwipeAction?
    /// The row's own background, which slides with it so the action shows only where it left.
    let rowBackground: Color
    /// Rows inside a grouped list's margins round the swipe's edges; edge-to-edge rows don't.
    let cornerRadius: CGFloat

    @State private var offset: CGFloat = 0
    /// Decided on a drag's first movement: true for a swipe, false for a scroll.
    @State private var sideways: Bool?
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        let armed = SwipeRule.outcome(offset)
        content
            .background(offset == 0 ? Color.clear : rowBackground)
            .offset(x: offset)
            .background { reveal(armed: armed) }
            // The row slides inside its own frame, never over the list's margins.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Simultaneous, so the list keeps scrolling: a plain gesture here blocks scrolling on iOS 18.
            .simultaneousGesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new != nil }
            // Ended or cancelled (a scroll or the back swipe took over): settle back.
            .onChange(of: dragging) { _, isDragging in
                if !isDragging { settle() }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if sideways == nil {
                    let fromEdge = value.startLocation.x < SwipeRule.edgeZone && value.translation.width > 0
                    sideways = !fromEdge && SwipeRule.isSideways(value.translation)
                }
                guard sideways == true else { return }
                offset = SwipeRule.offset(value.translation.width, canLead: leading != nil, canTrail: trailing != nil)
            }
            .onEnded { _ in
                let outcome = sideways == true ? SwipeRule.outcome(offset) : nil
                switch outcome {
                case .leading?: leading?.perform()
                case .trailing?: trailing?.perform()
                case nil: break
                }
                settle()
            }
    }

    private func settle() {
        sideways = nil
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
