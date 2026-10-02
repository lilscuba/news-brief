import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var working = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "newspaper.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("Brief")
                    .font(.largeTitle.bold())
                Text("Breaking gaming, tech and AI news from the outlets, official blogs and reporters who break it. One calm feed instead of endless scrolling.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                Feature(icon: "square.stack.3d.up", text: "35+ sources, the same story merged into one")
                Feature(icon: "checkmark.seal", text: "Every story labelled: confirmed, reported or rumor")
                Feature(icon: "bell.badge", text: "Push only for news that matters to you, max 5 a day")
            }
            Spacer()
            if working {
                ProgressView()
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
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Text("Your account stores only your feed settings. No name, email or reading history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
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
