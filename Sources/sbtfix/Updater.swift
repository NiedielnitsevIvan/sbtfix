import AppKit

/// A release, as returned by GitHub's releases API.
struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    let tagName: String
    let assets: [Asset]

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    func isNewer(than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }

    static func decode(_ json: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: json)
    }
}

/// "Check for Updates…": offers the latest GitHub release and installs it over the running app.
/// Only runs when the user asks, and it's the app's only network access.
///
/// Releases are ad-hoc signed, so the signature check catches a damaged download but can't prove who
/// built it. What guarantees the source is HTTPS from this repository.
@MainActor
enum Updater {
    private nonisolated static let latestRelease = URL(string: "https://api.github.com/repos/NiedielnitsevIvan/sbtfix/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/NiedielnitsevIvan/sbtfix/releases/latest")!
    private static var isRunning = false

    static func check(_ controller: HeadphoneController) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let current = Bundle.main.shortVersion
        do {
            let release = try await fetchLatestRelease()
            guard release.isNewer(than: current) else {
                show("sbtfix is up to date", "\(current) is the latest version.")
                return
            }
            let answer = show("sbtfix \(release.version) is available",
                              "You have \(current). sbtfix will restart, and macOS will ask for Bluetooth access again.",
                              buttons: ["Update and Restart", "Later"])
            guard answer == .alertFirstButtonReturn else { return }
            try await install(release)
            controller.tearDown() // so the new copy can open the control channel right away
            try await restart()
        } catch {
            let answer = show("Couldn't update sbtfix", error.localizedDescription,
                              buttons: ["Open Releases Page", "Close"])
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release {
        // The API allows 60 s of caching, which could hide a release published a moment ago.
        let request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
        return try Release.decode(data)
    }

    /// Replaces the running app, after checking the download is an intact copy of it at that version.
    private nonisolated static func install(_ release: Release) async throws {
        guard let asset = release.assets.first(where: { $0.name == "sbtfix.zip" }) else {
            throw UpdateError("The release has no sbtfix.zip.")
        }
        let (zip, response) = try await URLSession.shared.download(from: asset.browserDownloadUrl)
        try requireSuccess(response)
        let files = FileManager.default
        let app = Bundle.main.bundleURL
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer {
            try? files.removeItem(at: folder)
            try? files.removeItem(at: zip)
        }
        try run("/usr/bin/ditto", "-x", "-k", zip.path, folder.path)
        let new = folder.appendingPathComponent("sbtfix.app")
        guard let bundle = Bundle(url: new), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.shortVersion == release.version else {
            throw UpdateError("The downloaded app doesn't match the release.")
        }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", new.path)
        _ = try files.replaceItemAt(app, withItemAt: new, options: .usingNewMetadataOnly)
    }

    /// Opens the new copy, then quits. It needs its own instance because this one is still running: a shell
    /// script that waited for this process to exit never reopened the app in testing.
    private static func restart() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    private nonisolated static func requireSuccess(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw UpdateError("GitHub answered with status \(status ?? 0).") }
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
        let url = URL(fileURLWithPath: tool)
        let process = try Process.run(url, arguments: arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(url.lastPathComponent) failed with status \(process.terminationStatus).")
        }
    }

    @discardableResult
    private static func show(_ title: String, _ text: String, buttons: [String] = []) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal()
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) { errorDescription = description }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}
