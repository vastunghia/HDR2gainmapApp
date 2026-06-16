import AppKit
import Foundation

/// Checks GitHub Releases for a newer version of the app.
///
/// Uses the GitHub REST API (`releases/latest`) and compares the release tag against the
/// running app's `CFBundleShortVersionString`. Two entry points:
/// - ``checkManually()`` — always reports the result (up-to-date / new version / error) via an alert.
/// - ``checkAutomatically()`` — runs at most once per day, gated by a preference, and only surfaces
///   an alert when a newer version is found (silent otherwise / on error).
@MainActor
enum UpdateChecker {

    // MARK: Configuration

    /// GitHub repo, used both for the API request and the user-facing release page.
    private static let owner = "vastunghia"
    private static let repo = "HDR2gainmapApp"

    private static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    private static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// `UserDefaults` keys. `automaticUpdateCheck` is also surfaced as a toggle in Preferences.
    private static let automaticCheckKey = "automaticUpdateCheck"
    private static let lastCheckDateKey = "lastUpdateCheckDate"

    /// Minimum interval between automatic checks.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    // MARK: Version

    /// The running app's marketing version (e.g. "2.1.0").
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Public entry points

    /// User-initiated check (menu item / Preferences button). Always reports the outcome.
    static func checkManually() {
        Task {
            do {
                let (version, releaseURL) = try await fetchLatest()
                if isNewer(version, than: currentVersion) {
                    presentNewVersion(version, releaseURL: releaseURL)
                } else {
                    presentUpToDate()
                }
            } catch {
                presentError(error)
            }
        }
    }

    /// Launch-time check. No-op when disabled in Preferences or run within the last 24h.
    /// Only alerts when a newer version exists; silent on up-to-date or failure.
    static func checkAutomatically() {
        let defaults = UserDefaults.standard
        // Default to enabled when the key has never been written.
        if defaults.object(forKey: automaticCheckKey) != nil, !defaults.bool(forKey: automaticCheckKey) {
            return
        }
        if let last = defaults.object(forKey: lastCheckDateKey) as? Date,
           Date().timeIntervalSince(last) < automaticCheckInterval {
            return
        }

        Task {
            do {
                let (version, releaseURL) = try await fetchLatest()
                defaults.set(Date(), forKey: lastCheckDateKey)
                if isNewer(version, than: currentVersion) {
                    presentNewVersion(version, releaseURL: releaseURL)
                }
            } catch {
                // Stay silent on automatic failures (offline, rate-limited, etc.).
            }
        }
    }

    // MARK: Networking

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Fetches the latest release's version (tag without a leading "v") and its web page URL.
    private static func fetchLatest() async throws -> (version: String, releaseURL: URL) {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let url = URL(string: release.htmlURL) ?? releasesPage
        return (version, url)
    }

    // MARK: Version comparison

    /// True when `remote` is a strictly higher dotted-numeric version than `local`.
    /// Compares component by component (e.g. "2.10.0" > "2.9.0"); shorter versions are zero-padded.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(of: remote)
        let l = components(of: local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: Alerts

    private static func presentNewVersion(_ version: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = "A new version is available"
        alert.informativeText = "HDR2gainmapApp \(version) is available. You have \(currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "HDR2gainmapApp \(currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
