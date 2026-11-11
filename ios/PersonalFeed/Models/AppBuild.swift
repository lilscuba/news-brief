import Foundation

/// Which build of the app this is, shown at the bottom of Settings. The launcher stamps the build
/// with the commit it was made from and prints the same code when it installs, so after an update
/// the two can be compared: if Settings still shows the old code, the update didn't reach the phone.
enum AppBuild {
    /// "Brief 1.0 (1) · e0db854", or just "Brief 1.0 (1)" for a build from Xcode's Run button,
    /// which has no commit stamped in.
    static func summary(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let commit = (info?["BriefCommit"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var text = version.isEmpty ? "Brief" : "Brief \(version)"
        if !build.isEmpty { text += " (\(build))" }
        if !commit.isEmpty { text += " · \(commit)" }
        return text
    }
}
