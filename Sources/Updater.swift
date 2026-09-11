import AppKit
import Foundation
import Security

/// Checks GitHub Releases for a newer build and replaces the running app with
/// it.
///
/// The signature check in `verify(bundleAt:)` is the security boundary. An
/// update is staged only if it is signed by this project's Developer ID team,
/// carries the expected bundle identifier, passes Apple's notarization
/// assessment, and is strictly newer than the running version. A compromised
/// release feed, a swapped asset or a hijacked download therefore cannot
/// deliver code that this app will install: it can only cause the update to
/// fail. Nothing is ever replaced without the user asking for it.
/// Pinned identity of the only signer whose builds may be installed. Declared
/// outside the main-actor class so the verification below can read it from the
/// background task that performs it.
private enum UpdateIdentity {
    static let team = "DPLC4BD7ST"
    static let bundle = "com.bpmsupreme.MactivityMonitor"
}

@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    /// The public release feed. Only the asset URLs found here are fetched.
    private static let feedURL = URL(string: "https://api.github.com/repos/elDoof/Mactivity/releases/latest")!

    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading
        case verifying
        case readyToInstall(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// Where a verified update waits until the user chooses to install it.
    private var stagedBundle: URL?
    private var stagingRoot: URL?
    private var pendingDownload: URL?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Updating means replacing the bundle on disk, which only makes sense for
    /// a real installed app -- not for `swift run`, where there is no bundle.
    var canUpdate: Bool {
        Bundle.main.bundleIdentifier == UpdateIdentity.bundle
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: - Checking

    /// Runs at most once a day, and only if the user has left automatic checks
    /// on. Failures stay silent: an unreachable feed is not worth interrupting
    /// someone over.
    func checkInBackground() {
        guard canUpdate,
              UserDefaults.standard.bool(forKey: "automaticUpdateChecks") else { return }

        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.checkInterval { return }

        Task { await check(userInitiated: false) }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard canUpdate, !isBusy else { return }
        status = .checking

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            guard let latest = Version(release.tagName), let running = Version(currentVersion) else {
                throw UpdaterError.message("Could not read the version number of the latest release.")
            }
            guard latest > running else {
                status = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                throw UpdaterError.message("The latest release has no downloadable archive.")
            }

            pendingDownload = asset.downloadURL
            status = .available(latest.description)
        } catch {
            // A routine background check that cannot reach the network should
            // not leave an error sitting in the settings pane.
            status = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: Self.feedURL)
        request.setValue("Mactivity/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdaterError.message("The update service returned an unexpected response (\(code)).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Downloading and verification

    func downloadUpdate() {
        guard case .available = status, let source = pendingDownload else { return }
        Task { await download(from: source) }
    }

    private func download(from source: URL) async {
        status = .downloading
        discardStagedUpdate()

        do {
            // Everything lands in a directory we create, so the paths handed to
            // the installer below are never attacker-influenced.
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Mactivity-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            stagingRoot = root

            let (temporaryFile, response) = try await URLSession.shared.download(from: source)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdaterError.message("The download failed.")
            }

            let archive = root.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: temporaryFile, to: archive)

            status = .verifying
            let bundle = try Self.unpack(archive: archive, into: root)
            try Self.verify(bundleAt: bundle)

            // Refuse a downgrade, and refuse a build whose contents disagree
            // with the version the feed advertised.
            guard let staged = Self.version(ofBundleAt: bundle), let running = Version(currentVersion) else {
                throw UpdaterError.message("The downloaded application has no readable version number.")
            }
            guard staged > running else {
                throw UpdaterError.message("The downloaded application is not newer than the installed one.")
            }

            stagedBundle = bundle
            status = .readyToInstall(staged.description)
        } catch {
            discardStagedUpdate()
            status = .failed(Self.describe(error))
        }
    }

    /// Expands the archive with ditto, which preserves the bundle metadata that
    /// the code signature covers -- an ordinary unzip would invalidate it.
    private nonisolated static func unpack(archive: URL, into directory: URL) throws -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, directory.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw UpdaterError.message("The downloaded archive could not be expanded.")
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        guard let bundle = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.message("The downloaded archive did not contain an application.")
        }
        return bundle
    }

    /// The security boundary. Rejects anything not signed by the pinned team,
    /// not carrying the expected bundle identifier, or not notarized by Apple.
    private nonisolated static func verify(bundleAt url: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdaterError.message("The download is not a signed application.")
        }

        let requirementText = "anchor apple generic"
            + " and identifier \"\(UpdateIdentity.bundle)\""
            + " and certificate leaf[subject.OU] = \"\(UpdateIdentity.team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdaterError.message("The signature requirement could not be built.")
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                               | kSecCSCheckNestedCode
                               | kSecCSStrictValidate)
        let result = SecStaticCodeCheckValidity(code, flags, requirement)
        guard result == errSecSuccess else {
            throw UpdaterError.message("The download is not signed by the expected developer.")
        }

        // Gatekeeper's own assessment, which additionally requires that Apple
        // has notarized this exact build. The SecAssessment C API is not
        // exposed to Swift, so this runs the same check through spctl.
        let assessment = Process()
        assessment.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        assessment.arguments = ["--assess", "--type", "execute", url.path]
        assessment.standardOutput = FileHandle.nullDevice
        assessment.standardError = FileHandle.nullDevice
        try assessment.run()
        assessment.waitUntilExit()
        guard assessment.terminationStatus == 0 else {
            throw UpdaterError.message("The download has not been notarized by Apple.")
        }
    }

    private nonisolated static func version(ofBundleAt url: URL) -> Version? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let string = info["CFBundleShortVersionString"] as? String else { return nil }
        return Version(string)
    }

    // MARK: - Installing

    /// Hands the swap to a detached shell: the replacement cannot happen from
    /// inside the process whose bundle is being replaced. The old bundle is
    /// moved aside rather than deleted, so a failed copy can be rolled back
    /// instead of leaving the user with no app at all.
    func installAndRelaunch() {
        guard case .readyToInstall = status, let staged = stagedBundle else { return }

        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            status = .failed("\(parent.path) is not writable. Move Mactivity to your Applications folder and try again.")
            return
        }

        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        mv "$2" "$2.old" || exit 1
        if ! ditto "$3" "$2"; then
            rm -rf "$2"
            mv "$2.old" "$2"
            exit 1
        fi
        rm -rf "$2.old"
        [ -n "$4" ] && rm -rf "$4"
        open "$2"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Paths are passed as arguments rather than interpolated into the
        // script, so no path can be read as shell syntax.
        task.arguments = ["-c", script, "mactivity-update",
                          String(ProcessInfo.processInfo.processIdentifier),
                          destination.path,
                          staged.path,
                          stagingRoot?.path ?? ""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            status = .failed("The update could not be started: \(error.localizedDescription)")
            return
        }

        NSApp.terminate(nil)
    }

    func dismiss() {
        discardStagedUpdate()
        status = .idle
    }

    private func discardStagedUpdate() {
        if let root = stagingRoot {
            try? FileManager.default.removeItem(at: root)
        }
        stagedBundle = nil
        stagingRoot = nil
    }

    private static func describe(_ error: Error) -> String {
        if let updaterError = error as? UpdaterError { return updaterError.message }
        return (error as NSError).localizedDescription
    }
}

private struct UpdaterError: Error {
    let message: String
    static func message(_ text: String) -> UpdaterError { UpdaterError(message: text) }
}

private struct Release: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

/// Dotted numeric version, tolerant of the leading "v" that release tags carry.
struct Version: Comparable, CustomStringConvertible {
    private let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let fields = trimmed.split(separator: ".").map { field -> Int? in
            Int(field.prefix { $0.isNumber })
        }
        guard !fields.isEmpty, !fields.contains(where: { $0 == nil }) else { return nil }
        parts = fields.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
