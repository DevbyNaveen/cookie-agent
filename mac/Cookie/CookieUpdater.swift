//
//  CookieUpdater.swift
//  Cookie
//
//  Cookie updates itself from GitHub releases, without Sparkle or a Developer ID.
//  latest.json is checked 30 s after launch and every 6 hours (or from Settings → About).
//  A newer release is taken only when its Ed25519 signature matches the key below, its
//  archive matches the signed SHA-256, and the app inside is validly signed by the same
//  team as this one. Then the notch says it's ready; Restart swaps the app in a detached
//  step that keeps the old one until the new one says it's healthy, and puts it back if not.
//
//  Why this works without a Developer ID: URLSession downloads carry no quarantine, so
//  Gatekeeper never stops the new app, and every release is signed by the same team, so
//  macOS keeps Screen Recording, Accessibility, Microphone and Input Monitoring grants.
//

import AppKit
import CryptoKit
import Foundation
import Security

/// A dotted release version, compared number by number: 0.10.0 is newer than 0.9.3, 1.0 equals 1.0.0.
struct CookieVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }

    var description: String { numbers.map(String.init).joined(separator: ".") }

    private static func padded(_ left: CookieVersion, _ right: CookieVersion) -> ([Int], [Int]) {
        let count = max(left.numbers.count, right.numbers.count)
        return (left.numbers + Array(repeating: 0, count: count - left.numbers.count),
                right.numbers + Array(repeating: 0, count: count - right.numbers.count))
    }

    static func == (left: CookieVersion, right: CookieVersion) -> Bool {
        let (leftNumbers, rightNumbers) = padded(left, right)
        return leftNumbers == rightNumbers
    }

    static func < (left: CookieVersion, right: CookieVersion) -> Bool {
        let (leftNumbers, rightNumbers) = padded(left, right)
        return leftNumbers.lexicographicallyPrecedes(rightNumbers)
    }
}

enum CookieUpdateError: LocalizedError, Equatable {
    case notARelease(String)
    case badSignature
    case checksumMismatch
    case tooLarge
    case badBundle(String)
    case wrongTeam(expected: String, found: String)
    case unsignedRunningApp
    case notInApplications(String)
    case notWritable(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notARelease(let why): return "GitHub's answer isn't a Cookie release (\(why))."
        case .badSignature: return "Refused: the release isn't signed with Cookie's update key."
        case .checksumMismatch: return "Refused: the download doesn't match the release's SHA-256."
        case .tooLarge: return "Refused: the download is larger than any Cookie release."
        case .badBundle(let why): return "Refused: the app in the download \(why)."
        case .wrongTeam(let expected, let found): return "Refused: the new app is signed by team \(found), not \(expected)."
        case .unsignedRunningApp: return "This copy of Cookie isn't signed by a team, so it can't check an update. Install it with the one-line installer."
        case .notInApplications(let path): return "Cookie updates itself only from Applications; this copy runs from \(path)."
        case .notWritable(let path): return "Cookie can't replace itself: \(path) isn't writable. Run the install line again."
        case .network(let why): return "Couldn't reach GitHub (\(why))."
        }
    }
}

/// latest.json, as scripts/release.sh writes it.
struct CookieUpdateManifest: Codable, Equatable {
    let version: String
    let build: Int
    let url: String
    let sha256: String
    let signature: String
    let minimumSystemVersion: String
    let notes: String
    let publishedAt: String

    /// Archives come only from this repository's releases (GitHub then redirects to its file host).
    static let downloadPrefix = "https://github.com/DevbyNaveen/cookie-agent/releases/download/"
    static let maximumSize = 64 * 1024

    static func parse(_ data: Data) throws -> CookieUpdateManifest {
        guard data.count <= maximumSize else { throw CookieUpdateError.notARelease("too large") }
        let manifest: CookieUpdateManifest
        do { manifest = try JSONDecoder().decode(CookieUpdateManifest.self, from: data) } catch {
            throw CookieUpdateError.notARelease("not the expected JSON")
        }
        guard CookieVersion(manifest.version) != nil else { throw CookieUpdateError.notARelease("version \(manifest.version)") }
        guard manifest.build > 0 else { throw CookieUpdateError.notARelease("build \(manifest.build)") }
        guard manifest.url.hasPrefix(downloadPrefix), manifest.url.hasSuffix("/Cookie.zip"),
              let url = URL(string: manifest.url), url.scheme == "https", url.host == "github.com",
              !manifest.url.contains("..") else { throw CookieUpdateError.notARelease("download URL") }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CookieUpdateError.notARelease("SHA-256")
        }
        guard Data(base64Encoded: manifest.signature)?.count == 64 else { throw CookieUpdateError.notARelease("signature") }
        guard CookieVersion(manifest.minimumSystemVersion) != nil else { throw CookieUpdateError.notARelease("minimum macOS") }
        guard manifest.notes.count <= 4_000 else { throw CookieUpdateError.notARelease("notes") }
        return manifest
    }

    var downloadURL: URL { URL(string: url)! }
}

/// The SHA-256 and Ed25519 checks. The signature covers version, build and archive hash together
/// (scripts/update-key.swift signs the same bytes), so an old archive can't pose as a new release.
enum CookieUpdateVerifier {
    static func signedMessage(version: String, build: Int, sha256: String) -> Data {
        Data("cookie-update:v1\n\(version)\n\(build)\n\(sha256.lowercased())\n".utf8)
    }

    static func signatureIsValid(_ manifest: CookieUpdateManifest, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let signature = Data(base64Encoded: manifest.signature) else { return false }
        return publicKey.isValidSignature(signature, for: signedMessage(version: manifest.version, build: manifest.build, sha256: manifest.sha256))
    }

    /// Streamed, a megabyte at a time: the archive is a few hundred megabytes.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyArchive(_ file: URL, manifest: CookieUpdateManifest, publicKey: Curve25519.Signing.PublicKey) throws {
        guard signatureIsValid(manifest, publicKey: publicKey) else { throw CookieUpdateError.badSignature }
        guard try sha256Hex(of: file) == manifest.sha256 else { throw CookieUpdateError.checksumMismatch }
    }
}

/// The new app's code signature: valid all the way down, for every architecture, and by our team.
enum CookieCodeSignature {
    static let bundleIdentifier = "com.enkeon.cookie"

    /// The team that signed the running Cookie, or nil for an ad hoc (development) build.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(staticCode)
    }

    static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(staticCode)
    }

    private static func teamIdentifier(_ code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func requirement(teamIdentifier: String) -> String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func verify(bundle: URL, teamIdentifier: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw CookieUpdateError.badBundle("has no code signature")
        }
        let found = self.teamIdentifier(staticCode) ?? "none"
        guard found == teamIdentifier else { throw CookieUpdateError.wrongTeam(expected: teamIdentifier, found: found) }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(self.requirement(teamIdentifier: teamIdentifier) as CFString, SecCSFlags(), &requirement) == errSecSuccess else {
            throw CookieUpdateError.badBundle("can't be checked")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error) == errSecSuccess else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw CookieUpdateError.badBundle("has an invalid code signature (\(reason))")
        }
    }
}

/// Where everything goes for one install: the app replaced in place, the old one kept beside the updates.
struct CookieUpdateInstallPlan: Equatable {
    let currentApp: URL
    let stagedApp: URL
    let backupApp: URL
    let folder: URL

    /// Only a Cookie.app in /Applications or ~/Applications whose folder this user can write.
    static func make(currentApp: URL, stagedApp: URL, folder: URL, home: URL,
                     isWritable: (String) -> Bool) throws -> CookieUpdateInstallPlan {
        let app = currentApp.standardizedFileURL.resolvingSymlinksInPath()
        let parent = app.deletingLastPathComponent().path
        let allowed = ["/Applications", home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Applications").path]
        guard app.pathExtension == "app", allowed.contains(parent) else { throw CookieUpdateError.notInApplications(app.path) }
        guard isWritable(parent) else { throw CookieUpdateError.notWritable(parent) }
        guard isWritable(app.path) else { throw CookieUpdateError.notWritable(app.path) }
        return CookieUpdateInstallPlan(currentApp: app, stagedApp: stagedApp, backupApp: folder.appendingPathComponent("backup/Cookie.app"), folder: folder)
    }
}

/// When to check, when to install, and what the last install's outcome means.
enum CookieUpdatePolicy {
    static let firstCheckDelay: TimeInterval = 30
    static let checkInterval: TimeInterval = 6 * 3600
    /// The new app marks itself healthy after running this long; the installer waits up to `healthTimeout`.
    static let healthyAfter: TimeInterval = 20
    static let healthTimeout = 120
    static let busyRetry: TimeInterval = 10

    static func isNewer(_ manifest: CookieUpdateManifest, thanVersion version: String, build: Int) -> Bool {
        guard let offered = CookieVersion(manifest.version), let running = CookieVersion(version) else { return false }
        return offered > running || (offered == running && manifest.build > build)
    }

    static func supports(_ manifest: CookieUpdateManifest, systemVersion: String) -> Bool {
        guard let minimum = CookieVersion(manifest.minimumSystemVersion), let system = CookieVersion(systemVersion) else { return false }
        return system >= minimum
    }

    enum InstallDecision: Equatable {
        case now
        case waitFor(String)
    }

    /// Never in the middle of a dictation, a task or a recording: those would be cut off.
    static func installDecision(busyReasons: [String]) -> InstallDecision {
        busyReasons.isEmpty ? .now : .waitFor(busyReasons.joined(separator: " and "))
    }

    enum Outcome: Equatable {
        case installed(version: String, build: Int)
        /// The new app didn't come up healthy, so the installer put this one back; don't offer that build again.
        case rolledBack(version: String, build: Int)
        case failed(version: String, build: Int)
    }

    /// The installer's `result` file: "installed|rolled-back|failed <version> <build>".
    static func outcome(_ text: String) -> Outcome? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 3, CookieVersion(words[1]) != nil, let build = Int(words[2]) else { return nil }
        switch words[0] {
        case "installed": return .installed(version: words[1], build: build)
        case "rolled-back": return .rolledBack(version: words[1], build: build)
        case "failed": return .failed(version: words[1], build: build)
        default: return nil
        }
    }

    /// Only the build the installer is waiting for marks itself healthy; an old app put back never does.
    static func shouldMarkHealthy(pendingBuild: Int?, runningBuild: Int) -> Bool {
        pendingBuild == runningBuild
    }
}

/// The detached step that swaps the app while Cookie is quit, and undoes it if the new one doesn't come up.
enum CookieUpdateInstaller {
    /// sh <script> <pid> <current app> <staged app> <backup app> <updates folder> <version> <build> <health timeout s>
    /// COOKIE_UPDATE_LAUNCH replaces /usr/bin/open (the checks use it to stand in for a real launch).
    static let script = #"""
    #!/bin/sh
    # Cookie's update step. Runs detached after Cookie quits; keeps the old app until the new one is healthy.
    pid=$1 target=$2 staged=$3 backup=$4 folder=$5 version=$6 build=$7 timeout=${8:-120}
    log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$folder/update.log"; }
    result() { printf '%s %s %s\n' "$1" "$version" "$build" > "$folder/result"; log "$1 $version ($build)"; }
    launch() { ${COOKIE_UPDATE_LAUNCH:-/usr/bin/open} "$1"; }
    log "installing $version ($build) over $target"
    # 1. Cookie quits first (it asked to); after a minute the update is dropped and nothing is touched.
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      waited=$((waited + 1))
      if [ "$waited" -gt 600 ]; then result failed; rm -rf "$staged"; exit 1; fi
      sleep 0.1
    done
    # 2. The old app becomes the backup, the new one takes its place; any failure puts the old one back.
    rm -rf "$backup" "$folder/healthy"
    mkdir -p "$(dirname "$backup")"
    if ! mv "$target" "$backup"; then result failed; launch "$target"; exit 1; fi
    if ! mv "$staged" "$target"; then
      rm -rf "$target"; mv "$backup" "$target"; result failed; launch "$target"; exit 1
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
    # 3. The new app writes its build to "healthy" once it has run for a while; then the backup goes.
    launch "$target"
    waited=0
    while [ "$waited" -lt $((timeout * 10)) ]; do
      if [ "$(cat "$folder/healthy" 2>/dev/null)" = "$build" ]; then
        rm -rf "$backup" "$folder/healthy"; result installed; exit 0
      fi
      waited=$((waited + 1))
      sleep 0.1
    done
    # 4. Not healthy in time: stop it, put the old app back and start that one.
    pkill -f "$target/Contents/MacOS/Cookie" 2>/dev/null || true
    sleep 2
    pkill -9 -f "$target/Contents/MacOS/Cookie" 2>/dev/null || true
    rm -rf "$folder/failed.app"
    mv "$target" "$folder/failed.app" || rm -rf "$target"
    mv "$backup" "$target"
    result rolled-back
    launch "$target"
    """#

    /// Writes the script and starts it detached (nohup, backgrounded), so it outlives Cookie.
    static func launch(plan: CookieUpdateInstallPlan, manifest: CookieUpdateManifest, processID: Int32,
                       healthTimeout: Int = CookieUpdatePolicy.healthTimeout, environment: [String: String]? = nil) throws {
        let scriptFile = plan.folder.appendingPathComponent("install-update.sh")
        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptFile, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \"$0\" \"$@\" >/dev/null 2>&1 &", scriptFile.path,
                             "\(processID)", plan.currentApp.path, plan.stagedApp.path, plan.backupApp.path, plan.folder.path,
                             manifest.version, "\(manifest.build)", "\(healthTimeout)"]
        if let environment { process.environment = environment }
        try process.run()
        process.waitUntilExit()   // only the launcher; the script itself runs on in the background
    }
}

@MainActor
final class CookieUpdater: ObservableObject {
    /// The release key's public half (scripts/update-key.swift; the private half is in ~/.cookie-release).
    /// Changing it means every installed Cookie refuses every later update until reinstalled.
    static let publicKeyBase64 = "PY3mG5lNM2MAdk5Pfn20nxcqjNSs128N3Vp/jee66mw="
    static let latestURL = URL(string: "https://github.com/DevbyNaveen/cookie-agent/releases/latest/download/latest.json")!
    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/Updates")
    static let lastCheckedKey = "CookieUpdater.lastChecked"
    static let skippedBuildKey = "CookieUpdater.skippedBuild"
    static let announcedBuildKey = "CookieUpdater.announcedBuild"

    static let shared = CookieUpdater(environment: .live)

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updated(String)
        case unsupported(version: String, minimum: String)
        case skipped(String)
        case downloading(String)
        case ready(CookieUpdateManifest)
        case waiting(version: String, reason: String)
        case installing(String)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Checks for updates on its own."
            case .checking: return "Checking GitHub…"
            case .upToDate: return "Cookie is up to date."
            case .updated(let version): return "Updated to \(version)."
            case .unsupported(let version, let minimum): return "Cookie \(version) needs macOS \(minimum) or later."
            case .skipped(let version): return "Cookie \(version) didn't start on this Mac, so this version stays until the next release."
            case .downloading(let version): return "Downloading Cookie \(version)…"
            case .ready(let manifest): return "Cookie \(manifest.version) is ready · Restart to update."
            case .waiting(let version, let reason): return "Cookie \(version) installs when \(reason) ends."
            case .installing(let version): return "Installing Cookie \(version)…"
            case .failed(let message): return message
            }
        }
    }

    /// Everything outside this class it touches, so the checks can stand in for GitHub, the disk and quitting.
    struct Environment {
        var folder: URL
        var publicKey: Curve25519.Signing.PublicKey
        var currentVersion: String
        var currentBuild: Int
        var systemVersion: String
        var appURL: URL
        var home: URL
        var defaults: UserDefaults
        var fetch: (URL) async throws -> Data
        var download: (URL) async throws -> URL
        var unzip: (URL, URL) throws -> Void
        /// Throws unless the bundle is validly signed by the running app's team.
        var verifyBundle: (URL) throws -> Void
        var isWritable: (String) -> Bool
        var launchInstaller: (CookieUpdateInstallPlan, CookieUpdateManifest) throws -> Void
        var quit: () -> Void
        /// A Proof row: feature, summary, bytes.
        var record: (String, String, Int?) -> Void

        static var live: Environment {
            let info = Bundle.main.infoDictionary
            let system = ProcessInfo.processInfo.operatingSystemVersion
            return Environment(
                folder: CookieUpdater.defaultFolder,
                publicKey: try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CookieUpdater.publicKeyBase64)!),
                currentVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
                currentBuild: Int(info?["CFBundleVersion"] as? String ?? "") ?? 0,
                systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                appURL: Bundle.main.bundleURL,
                home: FileManager.default.homeDirectoryForCurrentUser,
                defaults: .standard,
                fetch: CookieUpdater.liveFetch,
                download: CookieUpdater.liveDownload,
                unzip: CookieUpdater.liveUnzip,
                verifyBundle: { bundle in
                    guard let team = CookieCodeSignature.runningTeamIdentifier() else { throw CookieUpdateError.unsignedRunningApp }
                    try CookieCodeSignature.verify(bundle: bundle, teamIdentifier: team)
                },
                isWritable: { FileManager.default.isWritableFile(atPath: $0) },
                launchInstaller: { plan, manifest in
                    try CookieUpdateInstaller.launch(plan: plan, manifest: manifest, processID: ProcessInfo.processInfo.processIdentifier)
                },
                quit: { NSApp.terminate(nil) },
                record: { feature, summary, bytes in
                    // Called only from CookieUpdater, which is main-actor.
                    MainActor.assumeIsolated {
                        _ = CookieProof.shared.record(.acted, feature: feature, summary: summary, destination: "GitHub", bytes: bytes)
                    }
                })
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    /// What would be cut off by a restart right now ("a dictation", "a meeting recording"…); empty when idle.
    var busyReasons: () -> [String] = { [] }
    /// A release is downloaded, verified and ready (once per build): the notch says so.
    var onReady: ((CookieUpdateManifest) -> Void)?

    private let environment: Environment
    /// The verified release waiting in `staged`, while Restart is pending or deferred.
    private var readyRelease: CookieUpdateManifest?
    private var checkTimer: Timer?
    private var waitTimer: Timer?

    init(environment: Environment) {
        self.environment = environment
        lastChecked = environment.defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    var currentVersionText: String { "\(environment.currentVersion) (\(environment.currentBuild))" }
    private var stagingFolder: URL { environment.folder.appendingPathComponent("staged") }
    private var pendingFile: URL { environment.folder.appendingPathComponent("pending") }
    private var healthyFile: URL { environment.folder.appendingPathComponent("healthy") }
    private var resultFile: URL { environment.folder.appendingPathComponent("result") }

    // MARK: - Launch

    /// The last install's outcome, the health mark if this is the build being installed, then the checks.
    func start() {
        readLastOutcome()
        if CookieUpdatePolicy.shouldMarkHealthy(pendingBuild: pendingBuild, runningBuild: environment.currentBuild) {
            Timer.scheduledTimer(withTimeInterval: CookieUpdatePolicy.healthyAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.markHealthy() }
            }
        } else {
            try? FileManager.default.removeItem(at: pendingFile)
        }
        Timer.scheduledTimer(withTimeInterval: CookieUpdatePolicy.firstCheckDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.check() } }
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: CookieUpdatePolicy.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.check() } }
        }
    }

    var pendingBuild: Int? {
        (try? String(contentsOf: pendingFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// This build ran long enough: the installer may delete the backup.
    func markHealthy() {
        guard CookieUpdatePolicy.shouldMarkHealthy(pendingBuild: pendingBuild, runningBuild: environment.currentBuild) else { return }
        try? Data("\(environment.currentBuild)\n".utf8).write(to: healthyFile, options: .atomic)
        try? FileManager.default.removeItem(at: pendingFile)
    }

    func readLastOutcome() {
        guard let text = try? String(contentsOf: resultFile, encoding: .utf8), let outcome = CookieUpdatePolicy.outcome(text) else { return }
        try? FileManager.default.removeItem(at: resultFile)
        switch outcome {
        case .installed(let version, let build) where build == environment.currentBuild:
            status = .updated(version)
            try? FileManager.default.removeItem(at: stagingFolder)
        case .rolledBack(let version, let build):
            environment.defaults.set(build, forKey: Self.skippedBuildKey)
            status = .skipped(version)
        case .failed(let version, _):
            status = .failed("Cookie \(version) couldn't be installed; Cookie will try again at the next check.")
        default:
            break
        }
    }

    // MARK: - Check and download

    func check() async {
        switch status {
        case .checking, .downloading, .installing, .waiting: return
        case .ready(let manifest):
            // Already verified and waiting for Restart; the notch was told once.
            if FileManager.default.fileExists(atPath: stagedApp(manifest).path) { return }
        default: break
        }
        status = .checking
        environment.record("update check", "asked GitHub for Cookie's latest version", nil)
        let manifest: CookieUpdateManifest
        do {
            manifest = try CookieUpdateManifest.parse(try await environment.fetch(Self.latestURL))
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't check for updates.")
            return
        }
        lastChecked = Date()
        environment.defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        guard CookieUpdatePolicy.isNewer(manifest, thanVersion: environment.currentVersion, build: environment.currentBuild) else {
            status = .upToDate
            return
        }
        if environment.defaults.integer(forKey: Self.skippedBuildKey) == manifest.build {
            status = .skipped(manifest.version)
            return
        }
        guard CookieUpdatePolicy.supports(manifest, systemVersion: environment.systemVersion) else {
            status = .unsupported(version: manifest.version, minimum: manifest.minimumSystemVersion)
            return
        }
        // The signature is checked before a byte of the archive is fetched.
        guard CookieUpdateVerifier.signatureIsValid(manifest, publicKey: environment.publicKey) else {
            status = .failed(CookieUpdateError.badSignature.errorDescription!)
            return
        }
        // Only a verified app is ever moved into `staged`, so one already there needs no second download.
        if !FileManager.default.fileExists(atPath: stagedApp(manifest).path) {
            status = .downloading(manifest.version)
            do {
                try await downloadAndVerify(manifest)
            } catch {
                try? FileManager.default.removeItem(at: stagingFolder)
                status = .failed((error as? LocalizedError)?.errorDescription ?? "The update didn't download.")
                return
            }
        }
        readyRelease = manifest
        status = .ready(manifest)
        if environment.defaults.integer(forKey: Self.announcedBuildKey) != manifest.build {
            environment.defaults.set(manifest.build, forKey: Self.announcedBuildKey)
            onReady?(manifest)
        }
    }

    private func stagedApp(_ manifest: CookieUpdateManifest) -> URL {
        stagingFolder.appendingPathComponent("\(manifest.build)/Cookie.app")
    }

    /// Download → SHA-256 + signature → unzip → the app inside is the release it claims and signed by our team.
    private func downloadAndVerify(_ manifest: CookieUpdateManifest) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagingFolder)
        let buildFolder = stagingFolder.appendingPathComponent("\(manifest.build)")
        try fileManager.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        let downloaded = try await environment.download(manifest.downloadURL)
        let archive = buildFolder.appendingPathComponent("Cookie.zip")
        try fileManager.moveItem(at: downloaded, to: archive)
        let size = (try fileManager.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        environment.record("update download", "downloaded Cookie \(manifest.version)", size)
        guard size <= 2_000_000_000 else { throw CookieUpdateError.tooLarge }
        try CookieUpdateVerifier.verifyArchive(archive, manifest: manifest, publicKey: environment.publicKey)
        let unpacked = buildFolder.appendingPathComponent("unpacked")
        try environment.unzip(archive, unpacked)
        try? fileManager.removeItem(at: archive)
        let app = unpacked.appendingPathComponent("Cookie.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw CookieUpdateError.badBundle("isn't Cookie.app")
        }
        guard info["CFBundleIdentifier"] as? String == CookieCodeSignature.bundleIdentifier else { throw CookieUpdateError.badBundle("isn't Cookie") }
        guard info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == "\(manifest.build)" else {
            throw CookieUpdateError.badBundle("is a different version than the release says")
        }
        try environment.verifyBundle(app)
        try fileManager.moveItem(at: app, to: stagedApp(manifest))
        try? fileManager.removeItem(at: unpacked)
    }

    // MARK: - Install

    /// Restart to update: now if nothing would be cut off, else as soon as it's over.
    func restartToUpdate() {
        guard let manifest = readyManifest else { return }
        switch CookieUpdatePolicy.installDecision(busyReasons: busyReasons()) {
        case .waitFor(let reason):
            status = .waiting(version: manifest.version, reason: reason)
            waitTimer?.invalidate()
            waitTimer = Timer.scheduledTimer(withTimeInterval: CookieUpdatePolicy.busyRetry, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartToUpdate() }
            }
        case .now:
            waitTimer?.invalidate()
            install(manifest)
        }
    }

    private var readyManifest: CookieUpdateManifest? {
        switch status {
        case .ready(let manifest): return manifest
        case .waiting: return readyRelease
        default: return nil
        }
    }

    private func install(_ manifest: CookieUpdateManifest) {
        do {
            let plan = try CookieUpdateInstallPlan.make(currentApp: environment.appURL, stagedApp: stagedApp(manifest),
                                                        folder: environment.folder, home: environment.home,
                                                        isWritable: environment.isWritable)
            try Data("\(manifest.build)\n".utf8).write(to: pendingFile, options: .atomic)
            try? FileManager.default.removeItem(at: healthyFile)
            try? FileManager.default.removeItem(at: resultFile)
            try environment.launchInstaller(plan, manifest)
            status = .installing(manifest.version)
            environment.quit()
        } catch {
            try? FileManager.default.removeItem(at: pendingFile)
            status = .failed((error as? LocalizedError)?.errorDescription ?? "The update couldn't start: \(error.localizedDescription)")
        }
    }

    // MARK: - Live network and disk

    private static func liveFetch(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw CookieUpdateError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw CookieUpdateError.network("no Cookie release is published yet") }
        guard code == 200 else { throw CookieUpdateError.network("HTTP \(code)") }
        return data
    }

    private static func liveDownload(_ url: URL) async throws -> URL {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
        let (file, response): (URL, URLResponse)
        do { (file, response) = try await URLSession.shared.download(for: request) } catch {
            throw CookieUpdateError.network(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw CookieUpdateError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return file
    }

    /// ditto, as Finder does: keeps the bundle's signature, symlinks and permissions exactly.
    nonisolated private static func liveUnzip(_ archive: URL, _ destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CookieUpdateError.badBundle("couldn't be unzipped") }
    }
}
