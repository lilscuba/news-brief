import SwiftUI

/// "Saved": a floppy disk drops into the middle of the screen, gets a tick and fades away. Shown
/// by MainTabs each time a story is saved, however it was saved (a swipe, the bookmark button, the
/// long-press menu, the tip). It never takes a touch, so the list underneath stays usable.
struct SavedFlash: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let confirmation: SaveConfirmation
    /// The card is on screen.
    @State private var shown = false
    /// The disk has landed and its tick is drawn.
    @State private var ticked = false

    /// How long it stays once it has landed.
    static let hold: Duration = .milliseconds(850)

    var body: some View {
        VStack(spacing: 12) {
            FloppyDisk(color: .orange)
                .frame(width: 72, height: 72)
                // On the disk's label, where a title would be written.
                .overlay(alignment: .bottom) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.orange)
                        .scaleEffect(ticked ? 1 : 0.3)
                        .opacity(ticked ? 1 : 0)
                        .padding(.bottom, 9)
                }
                // Drops in from above, like a disk going into a drive.
                .offset(y: shown || reduceMotion ? 0 : -34)
            Text("Saved")
                .font(.headline)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .scaleEffect(shown || reduceMotion ? 1 : 0.72)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: confirmation.id) {
            AccessibilityNotification.Announcement("Saved").post()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { shown = true }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(response: 0.26, dampingFraction: 0.5)) { ticked = true }
            try? await Task.sleep(for: Self.hold)
            withAnimation(.easeIn(duration: 0.22)) { shown = false }
            try? await Task.sleep(for: .milliseconds(240))
            // A newer save has its own card by now; only clear this one.
            if !Task.isCancelled, model.saveConfirmation?.id == confirmation.id { model.saveConfirmation = nil }
        }
    }
}

/// A 3.5-inch floppy disk, drawn from shapes (SF Symbols has none): the body with its clipped
/// corner, the metal shutter with its window, and the paper label.
struct FloppyDisk: View {
    var color: Color = .orange

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                FloppyBody()
                    .fill(color.gradient)
                // The shutter, with the darker window the drive reads through.
                RoundedRectangle(cornerRadius: side * 0.03, style: .continuous)
                    .fill(Color(white: 0.86))
                    .frame(width: side * 0.44, height: side * 0.3)
                    .overlay(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: side * 0.02, style: .continuous)
                            .fill(color)
                            .frame(width: side * 0.1, height: side * 0.2)
                            .padding(.trailing, side * 0.07)
                    }
                    .offset(x: side * 0.22, y: 0)
                // The label.
                RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                    .fill(.white)
                    .frame(width: side * 0.7, height: side * 0.4)
                    .offset(x: side * 0.15, y: side * 0.52)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The disk's outline: a rounded square with its top-right corner cut off.
struct FloppyBody: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.1
        let cut = rect.width * 0.17
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
