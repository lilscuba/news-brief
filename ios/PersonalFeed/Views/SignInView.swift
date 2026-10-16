import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var working = false
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

    var body: some View {
        // Scrolls when it doesn't fit (large text, landscape); centred when it does.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 0)
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)  // decorative; the title says it
                    VStack(spacing: 10) {
                        Text("Brief")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Breaking gaming, tech, AI and world news from the outlets, official blogs and reporters who break it. One calm feed instead of endless scrolling.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Feature(icon: "square.stack.3d.up", text: "170+ sources, the same story merged into one")
                        Feature(icon: "checkmark.seal", text: "Rumors and confirmed news clearly labelled")
                        Feature(icon: "bell.badge", text: "Push only for news that matters to you, 5 a day by default")
                    }
                    Spacer(minLength: 0)
                    signInButton
                    if let error = model.accountError {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                    }
                    Text("Your account stores only your feed settings. No name, email or reading history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: model.accountError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        if working {
            ProgressView("Signing in…")
                .frame(minHeight: 50)
        } else {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []  // no name or email needed
            } onCompletion: { result in
                working = true
                Task {
                    await model.signIn(with: result)
                    working = false
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
        }
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
        .font(.subheadline)
    }
}
