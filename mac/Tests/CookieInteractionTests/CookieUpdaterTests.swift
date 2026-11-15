import AppKit
import CryptoKit

/// Updates: versions compare by number; latest.json is refused unless every field is sane; an archive
/// installs only with the right SHA-256, the right Ed25519 key and our team's code signature; nothing
/// restarts over busy work; the app is replaced only in Applications; the installer really swaps the
/// app, keeps the backup until the new one is healthy, and puts the old one back when it isn't.
@MainActor
enum CookieUpdaterTests {
    static func run() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        // Versions: by number, not by text; missing parts are zero; anything else isn't a version.
        func version(_ text: String) -> CookieVersion { CookieVersion(text)! }
        check(version("0.10.0") > version("0.9.3") && version("0.2.0") > version("0.1.9") && version("1.0") == version("1.0.0")
              && version("2.0.0") > version("1.99.99") && !(version("0.2.0") < version("0.2")), "numeric comparison")
        check(["", "v1.0", "1..2", "1.a", "1.2.3.4.5", "-1", "1.2 ", "１.0", "1234567"].allSatisfy { CookieVersion($0) == nil }, "not versions")

        // Signing: a real key, the same message scripts/update-key.swift signs.
        let releaseKey = Curve25519.Signing.PrivateKey()
        let strangerKey = Curve25519.Signing.PrivateKey()
        func manifest(version: String = "0.2.0", build: Int = 5, sha256: String, key: Curve25519.Signing.PrivateKey = releaseKey,
                      url: String = "https://github.com/DevbyNaveen/cookie-agent/releases/download/v0.2.0/Cookie.zip",
                      minimum: String = "15.0", signedVersion: String? = nil) -> CookieUpdateManifest {
            let signature = try! key.signature(for: CookieUpdateVerifier.signedMessage(version: signedVersion ?? version, build: build, sha256: sha256))
            return CookieUpdateManifest(version: version, build: build, url: url, sha256: sha256, signature: signature.base64EncodedString(),
                                        minimumSystemVersion: minimum, notes: "Faster dictation.", publishedAt: "2026-11-15T12:00:00Z")
        }
        func json(_ release: CookieUpdateManifest) -> Data { try! JSONEncoder().encode(release) }
        let zeros = String(repeating: "0", count: 64)

        // latest.json: round-trips; refused for another host, plain http, a path escape, a bad hash or signature, a missing field.
        let good = manifest(sha256: zeros)
        check((try? CookieUpdateManifest.parse(json(good))) == good, "a release parses")
        for url in ["https://evil.example/DevbyNaveen/cookie-agent/releases/download/v0.2.0/Cookie.zip",
                    "http://github.com/DevbyNaveen/cookie-agent/releases/download/v0.2.0/Cookie.zip",
                    "https://github.com/someone/else/releases/download/v0.2.0/Cookie.zip",
                    "https://github.com/DevbyNaveen/cookie-agent/releases/download/../../x/Cookie.zip",
                    "https://github.com/DevbyNaveen/cookie-agent/releases/download/v0.2.0/Other.zip"] {
            check((try? CookieUpdateManifest.parse(json(manifest(sha256: zeros, url: url)))) == nil, "refused url \(url)")
        }
        check((try? CookieUpdateManifest.parse(json(manifest(sha256: "ABC")))) == nil, "a bad SHA-256 is refused")
        check((try? CookieUpdateManifest.parse(json(manifest(version: "two", sha256: zeros)))) == nil, "a bad version is refused")
        var shortSignature = try! JSONSerialization.jsonObject(with: json(good)) as! [String: Any]
        shortSignature["signature"] = Data(repeating: 1, count: 12).base64EncodedString()
        check((try? CookieUpdateManifest.parse(try! JSONSerialization.data(withJSONObject: shortSignature))) == nil, "a short signature is refused")
        shortSignature.removeValue(forKey: "signature")
        check((try? CookieUpdateManifest.parse(try! JSONSerialization.data(withJSONObject: shortSignature))) == nil, "a missing field is refused")
        check((try? CookieUpdateManifest.parse(Data("<html>rate limited</html>".utf8))) == nil, "not JSON is refused")

        // Newer: by version, then by build for a rebuilt release; never older.
        check(CookieUpdatePolicy.isNewer(good, thanVersion: "0.1.0", build: 1) && !CookieUpdatePolicy.isNewer(good, thanVersion: "0.2.0", build: 5)
              && CookieUpdatePolicy.isNewer(good, thanVersion: "0.2.0", build: 4) && !CookieUpdatePolicy.isNewer(good, thanVersion: "0.3.0", build: 1),
              "newer by version, then build")
        check(CookieUpdatePolicy.supports(good, systemVersion: "15.7.1") && !CookieUpdatePolicy.supports(good, systemVersion: "14.6")
              && CookieUpdatePolicy.supports(manifest(sha256: zeros, minimum: "26.0"), systemVersion: "27.0"), "minimum macOS")

        // SHA-256 + Ed25519: the archive's hash and the release key; tampering with either is refused.
        let archive = folder.appendingPathComponent("archive.bin")
        try! Data((0..<300_000).map { UInt8($0 % 251) }).write(to: archive)
        let archiveHash = try! CookieUpdateVerifier.sha256Hex(of: archive)
        check(archiveHash == SHA256.hash(data: try! Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined(), "streamed hash")
        let signed = manifest(sha256: archiveHash)
        check((try? CookieUpdateVerifier.verifyArchive(archive, manifest: signed, publicKey: releaseKey.publicKey)) != nil, "good archive verifies")
        check(refusal { try CookieUpdateVerifier.verifyArchive(archive, manifest: signed, publicKey: strangerKey.publicKey) } == .badSignature, "wrong key")
        check(refusal { try CookieUpdateVerifier.verifyArchive(archive, manifest: manifest(sha256: archiveHash, signedVersion: "0.1.0"),
                                                               publicKey: releaseKey.publicKey) } == .badSignature, "an old signature relabelled")
        var tampered = try! Data(contentsOf: archive)
        tampered[1234] ^= 0xFF
        try! tampered.write(to: archive)
        check(refusal { try CookieUpdateVerifier.verifyArchive(archive, manifest: signed, publicKey: releaseKey.publicKey) } == .checksumMismatch, "tampered bytes")

        // The release script's signer and the app agree byte for byte (scripts/update-key.swift verify).
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        tool.arguments = ["scripts/update-key.swift", "verify", releaseKey.publicKey.rawRepresentation.base64EncodedString(),
                          signed.version, "\(signed.build)", signed.sha256, signed.signature]
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try! tool.run()
        tool.waitUntilExit()
        check(tool.terminationStatus == 0, "update-key.swift verifies the app's signed message")

        // Code signature: a real, validly signed app by another team (Apple's own) is refused, as is a folder with none.
        check(refusal { try CookieCodeSignature.verify(bundle: URL(fileURLWithPath: "/System/Applications/Calculator.app"), teamIdentifier: "3Z97R7N3SR") }
              == .wrongTeam(expected: "3Z97R7N3SR", found: "none"), "another signer is refused")
        let unsigned = fakeApp(in: folder.appendingPathComponent("unsigned"), version: "0.2.0", build: 5)
        check(refusal { try CookieCodeSignature.verify(bundle: unsigned, teamIdentifier: "3Z97R7N3SR") } != nil, "an unsigned bundle is refused")
        check(CookieCodeSignature.requirement(teamIdentifier: "3Z97R7N3SR")
              == "identifier \"com.enkeon.cookie\" and anchor apple generic and certificate leaf[subject.OU] = \"3Z97R7N3SR\"", "team requirement")

        // The whole check: GitHub, download, verify, unzip, ready; refusals leave nothing behind.
        let releaseZip = folder.appendingPathComponent("release/Cookie.zip")
        try? FileManager.default.createDirectory(at: releaseZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fakeApp(in: folder.appendingPathComponent("release-src"), version: "0.2.0", build: 5)
        ditto(["-c", "-k", "--keepParent", folder.appendingPathComponent("release-src/Cookie.app").path, releaseZip.path])
        let releaseHash = try! CookieUpdateVerifier.sha256Hex(of: releaseZip)
        let release = manifest(sha256: releaseHash)

        final class Calls { var downloads = 0; var installs: [CookieUpdateInstallPlan] = []; var quits = 0; var ready = 0; var proof: [String] = [] }
        func makeUpdater(_ name: String, served: Data, archive: URL = releaseZip, verifyBundle: @escaping (URL) throws -> Void = { _ in },
                         version: String = "0.1.0", build: Int = 1, system: String = "15.7", appURL: URL? = nil,
                         writable: Bool = true) -> (CookieUpdater, Calls, UserDefaults, URL) {
            let calls = Calls()
            let updates = folder.appendingPathComponent("\(name)/Updates")
            let suite = "cookie-updater-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let environment = CookieUpdater.Environment(
                folder: updates, publicKey: releaseKey.publicKey, currentVersion: version, currentBuild: build, systemVersion: system,
                appURL: appURL ?? URL(fileURLWithPath: "/Applications/Cookie.app"), home: URL(fileURLWithPath: "/Users/someone"), defaults: defaults,
                fetch: { url in
                    precondition(url == CookieUpdater.latestURL)
                    return served
                },
                download: { _ in
                    calls.downloads += 1
                    let copy = folder.appendingPathComponent("\(name)-download-\(UUID().uuidString).zip")
                    try FileManager.default.copyItem(at: archive, to: copy)
                    return copy
                },
                unzip: { zip, destination in
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    ditto(["-x", "-k", zip.path, destination.path])
                },
                verifyBundle: verifyBundle,
                isWritable: { _ in writable },
                launchInstaller: { plan, _ in calls.installs.append(plan) },
                quit: { calls.quits += 1 },
                record: { feature, _, _ in calls.proof.append(feature) })
            let updater = CookieUpdater(environment: environment)
            updater.onReady = { _ in calls.ready += 1 }
            return (updater, calls, defaults, updates)
        }

        let (updater, calls, defaults, updates) = makeUpdater("good", served: json(release))
        await updater.check()
        check(updater.status == .ready(release) && calls.ready == 1 && calls.downloads == 1, "verified and ready: \(updater.status)")
        check(calls.proof == ["update check", "update download"], "Proof rows for the check and the download: \(calls.proof)")
        check(FileManager.default.fileExists(atPath: updates.appendingPathComponent("staged/5/Cookie.app/Contents/Info.plist").path), "staged")
        check(updater.lastChecked != nil && defaults.object(forKey: CookieUpdater.lastCheckedKey) != nil, "last check kept")
        await updater.check()
        check(calls.ready == 1 && calls.downloads == 1, "announced once, downloaded once")

        // Busy: Restart waits for the dictation, then installs and quits.
        var busy = ["the dictation"]
        updater.busyReasons = { busy }
        updater.restartToUpdate()
        check(updater.status == .waiting(version: "0.2.0", reason: "the dictation") && calls.installs.isEmpty && calls.quits == 0, "deferred while busy")
        busy = ["the meeting recording", "the task"]
        updater.restartToUpdate()
        check(updater.status == .waiting(version: "0.2.0", reason: "the meeting recording and the task") && calls.installs.isEmpty, "still deferred")
        busy = []
        updater.restartToUpdate()
        check(calls.installs.count == 1 && calls.quits == 1 && updater.status == .installing("0.2.0"), "installs once idle")
        check(calls.installs[0].backupApp == updates.appendingPathComponent("backup/Cookie.app")
              && calls.installs[0].stagedApp == updates.appendingPathComponent("staged/5/Cookie.app"), "plan paths")
        check((try? String(contentsOf: updates.appendingPathComponent("pending"), encoding: .utf8)) == "5\n", "pending build recorded")

        // Refusals: each stops before installing and says why.
        let wrongKey = manifest(sha256: releaseHash, key: strangerKey)
        let (refusedKey, refusedKeyCalls, _, _) = makeUpdater("wrong-key", served: json(wrongKey))
        await refusedKey.check()
        check(refusedKey.status == .failed(CookieUpdateError.badSignature.errorDescription!) && refusedKeyCalls.downloads == 0, "wrong key: nothing downloaded")
        let (refusedHash, refusedHashCalls, _, refusedHashFolder) = makeUpdater("wrong-hash", served: json(manifest(sha256: zeros)))
        await refusedHash.check()
        check(refusedHash.status == .failed(CookieUpdateError.checksumMismatch.errorDescription!) && refusedHashCalls.ready == 0
              && !FileManager.default.fileExists(atPath: refusedHashFolder.appendingPathComponent("staged").path), "checksum mismatch: nothing kept")
        let (refusedTeam, _, _, _) = makeUpdater("wrong-team", served: json(release), verifyBundle: { _ in
            throw CookieUpdateError.wrongTeam(expected: "3Z97R7N3SR", found: "AAAAAAAAAA")
        })
        await refusedTeam.check()
        check(refusedTeam.status == .failed("Refused: the new app is signed by team AAAAAAAAAA, not 3Z97R7N3SR."), "wrong team: \(refusedTeam.status)")
        let (refusedVersion, _, _, _) = makeUpdater("relabelled", served: json(manifest(version: "0.3.0", sha256: releaseHash)))
        await refusedVersion.check()
        check(refusedVersion.status == .failed(CookieUpdateError.badBundle("is a different version than the release says").errorDescription!),
              "an app that isn't the version the release names: \(refusedVersion.status)")
        let (oldMac, oldMacCalls, _, _) = makeUpdater("old-mac", served: json(release), system: "14.7")
        await oldMac.check()
        check(oldMac.status == .unsupported(version: "0.2.0", minimum: "15.0") && oldMacCalls.downloads == 0, "too old a macOS")
        let (current, currentCalls, _, _) = makeUpdater("current", served: json(release), version: "0.2.0", build: 5)
        await current.check()
        check(current.status == .upToDate && currentCalls.downloads == 0, "up to date")
        let (garbage, _, _, _) = makeUpdater("garbage", served: Data("{}".utf8))
        await garbage.check()
        check(garbage.status == .failed(CookieUpdateError.notARelease("not the expected JSON").errorDescription!), "not a release")

        // Not in Applications, or not writable: ready, but Restart says why instead of quitting.
        let (desktop, desktopCalls, _, _) = makeUpdater("desktop", served: json(release), appURL: URL(fileURLWithPath: "/Users/someone/Desktop/Cookie.app"))
        await desktop.check()
        desktop.restartToUpdate()
        check(desktop.status == .failed(CookieUpdateError.notInApplications("/Users/someone/Desktop/Cookie.app").errorDescription!)
              && desktopCalls.quits == 0 && desktopCalls.installs.isEmpty, "only from Applications: \(desktop.status)")
        let (locked, lockedCalls, _, _) = makeUpdater("locked", served: json(release), writable: false)
        await locked.check()
        locked.restartToUpdate()
        check(locked.status == .failed(CookieUpdateError.notWritable("/Applications").errorDescription!) && lockedCalls.quits == 0, "not writable")

        // Install plan: /Applications and ~/Applications only, through symlinks; writable folder and bundle.
        let home = URL(fileURLWithPath: "/Users/someone")
        let staged = URL(fileURLWithPath: "/tmp/staged/Cookie.app")
        func plan(_ path: String, writable: Set<String>? = nil) -> CookieUpdateInstallPlan? {
            try? CookieUpdateInstallPlan.make(currentApp: URL(fileURLWithPath: path), stagedApp: staged, folder: folder, home: home,
                                              isWritable: { writable?.contains($0) ?? true })
        }
        check(plan("/Applications/Cookie.app")?.currentApp.path == "/Applications/Cookie.app"
              && plan("/Users/someone/Applications/Cookie.app")?.currentApp.path == "/Users/someone/Applications/Cookie.app"
              && plan("/Applications/../Applications/Cookie.app") != nil, "Applications folders")
        check(plan("/Users/someone/Downloads/Cookie.app") == nil && plan("/Volumes/Cookie/Cookie.app") == nil
              && plan("/Applications/Utilities/Cookie.app") == nil && plan("/Applications/Cookie") == nil, "anywhere else is refused")
        check(plan("/Applications/Cookie.app", writable: ["/Applications"]) == nil
              && plan("/Applications/Cookie.app", writable: ["/Applications/Cookie.app"]) == nil, "needs the folder and the bundle writable")

        // Health and rollback: only the build being installed marks itself healthy; the installer's verdict is read once.
        check(CookieUpdatePolicy.shouldMarkHealthy(pendingBuild: 5, runningBuild: 5) && !CookieUpdatePolicy.shouldMarkHealthy(pendingBuild: 5, runningBuild: 1)
              && !CookieUpdatePolicy.shouldMarkHealthy(pendingBuild: nil, runningBuild: 5), "health mark")
        check(CookieUpdatePolicy.outcome("rolled-back 0.2.0 5\n") == .rolledBack(version: "0.2.0", build: 5)
              && CookieUpdatePolicy.outcome("installed 0.2.0 5") == .installed(version: "0.2.0", build: 5)
              && CookieUpdatePolicy.outcome("failed 0.2.0 5") == .failed(version: "0.2.0", build: 5)
              && CookieUpdatePolicy.outcome("weird 0.2.0 5") == nil && CookieUpdatePolicy.outcome("") == nil, "outcomes")
        let (newApp, _, _, newUpdates) = makeUpdater("health", served: json(release), version: "0.2.0", build: 5)
        try? FileManager.default.createDirectory(at: newUpdates, withIntermediateDirectories: true)
        try! Data("5\n".utf8).write(to: newUpdates.appendingPathComponent("pending"))
        newApp.markHealthy()
        check((try? String(contentsOf: newUpdates.appendingPathComponent("healthy"), encoding: .utf8)) == "5\n"
              && !FileManager.default.fileExists(atPath: newUpdates.appendingPathComponent("pending").path), "the new build marks itself healthy")
        let (oldApp, oldCalls, oldDefaults, oldUpdates) = makeUpdater("rolled-back", served: json(release))
        try? FileManager.default.createDirectory(at: oldUpdates, withIntermediateDirectories: true)
        try! Data("5\n".utf8).write(to: oldUpdates.appendingPathComponent("pending"))
        oldApp.markHealthy()
        check(!FileManager.default.fileExists(atPath: oldUpdates.appendingPathComponent("healthy").path), "the old build never marks the new one healthy")
        try! Data("rolled-back 0.2.0 5\n".utf8).write(to: oldUpdates.appendingPathComponent("result"))
        oldApp.readLastOutcome()
        check(oldApp.status == .skipped("0.2.0") && oldDefaults.integer(forKey: CookieUpdater.skippedBuildKey) == 5
              && !FileManager.default.fileExists(atPath: oldUpdates.appendingPathComponent("result").path), "rolled back: that build is skipped")
        await oldApp.check()
        check(oldApp.status == .skipped("0.2.0") && oldCalls.downloads == 0, "a build that failed here isn't offered again")

        // The installer script itself, on real folders: swap + health = installed; no health = old app back.
        func scenario(_ name: String) -> (target: URL, staged: URL, backup: URL, updates: URL) {
            let root = folder.appendingPathComponent("script-\(name)")
            let target = fakeApp(in: root.appendingPathComponent("Applications"), version: "0.1.0", build: 1)
            let staged = fakeApp(in: root.appendingPathComponent("Updates/staged/5"), version: "0.2.0", build: 5)
            return (target, staged, root.appendingPathComponent("Updates/backup/Cookie.app"), root.appendingPathComponent("Updates"))
        }
        func appVersion(_ app: URL) -> String? {
            (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
        }
        let launcher = folder.appendingPathComponent("launch.sh")
        // Stands in for `open`: a healthy new app writes its build to "healthy"; an unhealthy one never does.
        try! Data("#!/bin/sh\necho \"$1\" >> \"$FAKE_UPDATES/launched\"\n[ -n \"$FAKE_HEALTHY\" ] && echo 5 > \"$FAKE_UPDATES/healthy\"\nexit 0\n".utf8).write(to: launcher)
        chmod(launcher.path, 0o755)
        let quitProcess = Process()
        quitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! quitProcess.run()
        quitProcess.waitUntilExit()

        let healthy = scenario("healthy")
        let healthyPlan = CookieUpdateInstallPlan(currentApp: healthy.target, stagedApp: healthy.staged, backupApp: healthy.backup, folder: healthy.updates)
        var environment = ProcessInfo.processInfo.environment
        environment["COOKIE_UPDATE_LAUNCH"] = launcher.path
        environment["FAKE_UPDATES"] = healthy.updates.path
        environment["FAKE_HEALTHY"] = "1"
        // Through the real detached launch, as Cookie does it.
        try! CookieUpdateInstaller.launch(plan: healthyPlan, manifest: release, processID: quitProcess.processIdentifier,
                                          healthTimeout: 10, environment: environment)
        let resultFile = healthy.updates.appendingPathComponent("result")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: resultFile.path) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        check((try? String(contentsOf: resultFile, encoding: .utf8)) == "installed 0.2.0 5\n", "installed")
        check(appVersion(healthy.target) == "0.2.0" && !FileManager.default.fileExists(atPath: healthy.backup.path)
              && !FileManager.default.fileExists(atPath: healthy.staged.path), "new app in place, backup gone")

        let broken = scenario("broken")
        environment["FAKE_UPDATES"] = broken.updates.path
        environment["FAKE_HEALTHY"] = ""
        let script = broken.updates.appendingPathComponent("install-update.sh")
        try! Data(CookieUpdateInstaller.script.utf8).write(to: script)
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = [script.path, "\(quitProcess.processIdentifier)", broken.target.path, broken.staged.path, broken.backup.path,
                         broken.updates.path, "0.2.0", "5", "1"]
        run.environment = environment
        try! run.run()
        while run.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        check((try? String(contentsOf: broken.updates.appendingPathComponent("result"), encoding: .utf8)) == "rolled-back 0.2.0 5\n", "rolled back")
        check(appVersion(broken.target) == "0.1.0" && appVersion(broken.updates.appendingPathComponent("failed.app")) == "0.2.0"
              && !FileManager.default.fileExists(atPath: broken.backup.path), "old app back, the failed one set aside")
        let launched = (try? String(contentsOf: broken.updates.appendingPathComponent("launched"), encoding: .utf8)) ?? ""
        check(launched == "\(broken.target.path)\n\(broken.target.path)\n", "launched the new app, then the old one again: \(launched)")

        print("\(checks) updater checks passed.")
    }

    private static func refusal(_ body: () throws -> Void) -> CookieUpdateError? {
        do { try body(); return nil } catch { return error as? CookieUpdateError }
    }

    /// A Cookie.app-shaped folder: an Info.plist naming the version, and a tiny "executable".
    @discardableResult
    private static func fakeApp(in parent: URL, version: String, build: Int) -> URL {
        let app = parent.appendingPathComponent("Cookie.app")
        let contents = app.appendingPathComponent("Contents/MacOS")
        try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.enkeon.cookie", "CFBundleShortVersionString": version,
                                  "CFBundleVersion": "\(build)", "CFBundleExecutable": "Cookie"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: contents.appendingPathComponent("Cookie"))
        chmod(contents.appendingPathComponent("Cookie").path, 0o755)
        return app
    }

    private static func ditto(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ditto \(arguments)")
    }
}
