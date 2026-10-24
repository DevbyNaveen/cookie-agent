//
//  CookieSafety.swift
//  Cookie
//
//  What keeps Cookie from seeing, keeping or leaking what it shouldn't.
//  Threat model and sources: SECURITY.md at the repo root.
//
//  CaptureGuard — refuses to look while a password is being typed, a secure
//                 field is focused, or a blocked app (password manager,
//                 banking) is in front; blocked apps are also cut out of
//                 every screenshot.
//  Redactor     — on this Mac, before anything is sent: card numbers, IBANs
//                 and API keys/private keys are blacked out, faces blurred;
//                 a picture whose text can't be checked is not sent at all.
//  ChatVault    — chats are AES-GCM encrypted at rest, key in the Keychain.
//  ChatLock     — optional Touch ID before chats are shown.
//

import AppKit
import ApplicationServices
import Carbon
import CoreImage
import CryptoKit
import LocalAuthentication
import Security
import Vision

// MARK: - Capture guard

enum CaptureGuard {
    /// Apps Cookie never looks at. Users can add their own (Settings → Privacy).
    static let defaultBlockedApps: [String: String] = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.lastpass.LastPass": "LastPass",
        "com.apple.Passwords": "Passwords",
        "com.apple.keychainaccess": "Keychain Access",
    ]

    static let userBlockedKey = "cookie.blockedApps"

    /// Every blocked bundle id: the built-in list plus the user's.
    static var blockedBundleIDs: Set<String> {
        Set(defaultBlockedApps.keys).union(UserDefaults.standard.stringArray(forKey: userBlockedKey) ?? [])
    }

    /// Why Cookie must not look right now, or nil when it may.
    @MainActor
    static func refusal() -> String? {
        // TN2150: set while any app (Terminal, browsers, login fields) takes a password.
        if IsSecureEventInputEnabled() {
            return "Cookie doesn't look while a password is being typed."
        }
        if focusedElementIsSecure() {
            return "Cookie doesn't look while a password field is selected."
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, blockedBundleIDs.contains(id) {
            return "Cookie doesn't look at \(front.localizedName ?? "this app")."
        }
        return nil
    }

    /// AXSecureTextField is the subrole every native password field reports.
    static func focusedElementIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        AXUIElementSetMessagingTimeout(element as! AXUIElement, 0.2)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }
}

/// Whether a reply looks at the screen. Only the person decides: talking and
/// circling ask for it, typing asks only with the screen button. Never the
/// model, never Cookie on its own.
enum ScreenLook: Equatable {
    case look
    case notAsked
    case refused(String)

    static func decide(asked: Bool, screenAllowed: Bool, refusal: () -> String?) -> ScreenLook {
        guard asked else { return .notAsked }
        guard screenAllowed else { return .refused("Screen access is off") }
        return refusal().map(ScreenLook.refused) ?? .look
    }
}

/// Resolves once, including cancellation before the continuation is installed.
private final class DeadlineWait<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value?, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { self.continuation = continuation }
        lock.unlock()
        if alreadyFinished { continuation.resume(returning: nil) }
    }

    func track(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { self.tasks = tasks }
        lock.unlock()
        if alreadyFinished { tasks.forEach { $0.cancel() } }
    }

    func finish(_ value: Value?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation
        let running = tasks
        continuation = nil
        tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        waiting?.resume(returning: value)
    }
}

/// An unresponsive OS capture must not hold up cancellation or the next question.
func withDeadline<T>(seconds: Double, _ work: @escaping () async throws -> T) async -> T? {
    let wait = DeadlineWait<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            wait.install(continuation)
            guard !Task.isCancelled else { wait.finish(nil); return }
            let operation = Task { wait.finish(try? await work()) }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                wait.finish(nil)
            }
            wait.track([operation, timeout])
        }
    } onCancel: {
        wait.finish(nil)
    }
}

// MARK: - Redactor

/// Runs on the Mac, before upload. A safeguard, not a guarantee: OCR can
/// miss text (Recall's filter did too), which is why the capture guard and
/// the blocked-app list come first.
enum Redactor {
    static let hideSecretsKey = "cookie.redactSecrets"
    static let blurFacesKey = "cookie.blurFaces"

    struct Result {
        let image: CGImage
        let hiddenText: Int
        let blurredFaces: Int
        /// Face detection failed: the picture went with its text checked but faces not blurred.
        var facesUnchecked = false
    }

    /// Text recognition failed outright while secret hiding is on: the picture must not be sent.
    struct Unchecked: LocalizedError {
        var errorDescription: String? { "Couldn't check the screenshot for private details, so it wasn't sent" }
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func redact(_ image: CGImage) throws -> Result {
        let defaults = UserDefaults.standard
        let hideSecrets = defaults.object(forKey: hideSecretsKey) as? Bool ?? true
        let blurFaces = defaults.object(forKey: blurFacesKey) as? Bool ?? true
        guard hideSecrets || blurFaces else { return Result(image: image, hiddenText: 0, blurredFaces: 0) }

        var textBoxes: [CGRect] = []
        var faceBoxes: [CGRect] = []
        var facesUnchecked = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Fail closed: a picture whose text couldn't be read is never sent unchecked.
        if hideSecrets {
            let lines: [VNRecognizedText]
            do { lines = try CookieVisionText.recognize(handler) } catch {
                print("⚠️ Redactor: text recognition failed, not sending: \(error)")
                throw Unchecked()
            }
            for candidate in lines {
                for range in SensitiveText.ranges(in: candidate.string) {
                    if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                        textBoxes.append(box)
                    }
                }
            }
        }
        if blurFaces {
            let faceRequest = VNDetectFaceRectanglesRequest()
            do {
                try handler.perform([faceRequest])
                faceBoxes = (faceRequest.results ?? []).map(\.boundingBox)
            } catch {
                print("⚠️ Redactor: face detection failed: \(error)")
                facesUnchecked = true
            }
        }
        guard !textBoxes.isEmpty || !faceBoxes.isEmpty else {
            return Result(image: image, hiddenText: 0, blurredFaces: 0, facesUnchecked: facesUnchecked)
        }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision boxes are normalised with a bottom-left origin, as is Core Image.
        func pixels(_ box: CGRect, pad: CGFloat) -> CGRect {
            CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
                .insetBy(dx: -pad, dy: -pad)
        }

        var output = CIImage(cgImage: image)
        let base = output
        for box in faceBoxes {
            let rect = pixels(box, pad: 12)
            let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: max(18, rect.width / 6)).cropped(to: rect)
            output = blurred.composited(over: output)
        }
        for box in textBoxes {
            let block = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: pixels(box, pad: 3))
            output = block.composited(over: output)
        }
        guard let rendered = context.createCGImage(output, from: base.extent) else {
            print("⚠️ Redactor: couldn't render the redacted picture, not sending")
            throw Unchecked()
        }
        return Result(image: rendered, hiddenText: textBoxes.count, blurredFaces: faceBoxes.count, facesUnchecked: facesUnchecked)
    }
}

/// Strings that must never leave the Mac in a screenshot.
enum SensitiveText {
    private static let patterns: [NSRegularExpression] = [
        // Card numbers: 13–19 digits, optionally grouped. Checked with Luhn below.
        #"\b(?:\d[ -]?){12,18}\d\b"#,
        // IBAN: country, check digits, 11–30 alphanumerics (spaces allowed). Checked mod-97 below.
        #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#,
        // API keys and tokens with well-known prefixes.
        #"\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abpors]-[A-Za-z0-9-]{10,}|tr_(?:sk|pk|em)_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_\-]{35}|glpat-[A-Za-z0-9_\-]{20,})"#,
        // JSON Web Tokens.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // PEM private keys (the header line is enough to hide the block start).
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func ranges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Range<String.Index>] = []
        for (index, pattern) in patterns.enumerated() {
            for match in pattern.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let value = String(text[range])
                switch index {
                case 0: if luhn(value) { found.append(range) }
                case 1: if iban(value) { found.append(range) }
                default: found.append(range)
                }
            }
        }
        return found
    }

    static func luhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 { let doubled = digit * 2; sum += doubled > 9 ? doubled - 9 : doubled } else { sum += digit }
        }
        return sum % 10 == 0
    }

    static func iban(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let number = character.isNumber ? character.wholeNumberValue
                    : character.isLetter ? Int(character.asciiValue ?? 0) - 55 : nil else { return false }
            for digit in String(number) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }
}

// MARK: - Chat vault

/// Chats at rest: AES-256-GCM, the key in the Keychain, folder 0700, file 0600.
enum ChatVault {
    private static let service = "com.enkeon.cookie.chats"
    private static let account = "chat-key-v1"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cookie", isDirectory: true)
    }
    static var encryptedFile: URL { directory.appendingPathComponent("threads.sealed") }
    static var legacyPlaintextFile: URL { directory.appendingPathComponent("threads.json") }

    static func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key()).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key())
    }

    enum StoreError: Error {
        /// The Keychain would not hand over the key: a build it has not been told to trust, a
        /// denied or missed prompt. The file is untouched and must not be saved over this session.
        case keyWithheld(Error)
        /// The file did not open with the key, or did not decode; it was set aside, not deleted.
        case setAside
    }

    /// Stores whose file could not be opened because the key was withheld. Saving one would
    /// write what is in memory (nothing) over chats that are fine, once a later prompt is allowed.
    private static var withheld: Set<URL> = []

    static func isWithheld(_ file: URL) -> Bool { withheld.contains(file) }

    /// A store's sealed file, opened and decoded; nil when there is none yet. Only a file that
    /// fails to open with the key, or to decode, is set aside (`<name>.unreadable-<time>.sealed`).
    static func openStore<Value>(_ file: URL, name: String, decode: (Data) throws -> Value) throws -> Value? {
        guard let sealed = try? Data(contentsOf: file) else { return nil }
        let key: SymmetricKey
        do {
            key = try self.key()
        } catch {
            withheld.insert(file)
            throw StoreError.keyWithheld(error)
        }
        do {
            return try decode(AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key))
        } catch {
            let aside = directory.appendingPathComponent("\(name).unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
            try? FileManager.default.moveItem(at: file, to: aside)
            throw StoreError.setAside
        }
    }

    /// What a store says when its key was withheld.
    static func withheldProblem(_ what: String) -> String {
        "Cookie couldn't get its key from the Keychain, so your \(what) stay closed and untouched. Quit Cookie, open it again and choose Always Allow."
    }

    static func write(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try seal(data).write(to: encryptedFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encryptedFile.path)
    }

    /// Overwrites a plaintext file before removing it, so the old chats are
    /// not left readable in free space on a non-APFS-encrypted disk.
    static func destroy(_ url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Data(count: Int(size)))
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Key

    private static var cachedKey: SymmetricKey?

    private static func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let existing = try readKey() { cachedKey = existing; return existing }
        let fresh = SymmetricKey(size: .bits256)
        try storeKey(fresh)
        cachedKey = fresh
        return fresh
    }

    private static func readKey() throws -> SymmetricKey? {
        try CookieKeychain.read(service: service, account: account).map { SymmetricKey(data: $0) }
    }

    private static func storeKey(_ key: SymmetricKey) throws {
        try CookieKeychain.add(key.withUnsafeBytes { Data($0) }, service: service, account: account)
    }
}

// MARK: - Keychain

/// Generic-password items, this device only. The data-protection keychain
/// needs an application-identifier entitlement from a provisioning profile;
/// until Cookie ships with one, items go to the login keychain, whose access
/// list is bound to Cookie's code signature — another app reading them gets
/// a password prompt, not the secret.
enum CookieKeychain {
    private static func baseQuery(service: String, account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func read(service: String, account: String) throws -> Data? {
        for dataProtection in [true, false] {
            var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data { return data }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        return nil
    }

    static func add(_ data: Data, service: String, account: String) throws {
        var attributes = baseQuery(service: service, account: account, dataProtection: true)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            attributes = baseQuery(service: service, account: account, dataProtection: false)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Replaces the item: removed from both keychains, then added.
    static func set(_ data: Data, service: String, account: String) throws {
        delete(service: service, account: account)
        try add(data, service: service, account: account)
    }

    static func delete(service: String, account: String) {
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(service: service, account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }
}

// MARK: - Chat lock

/// Optional: Touch ID (or the Mac password) before chats are shown.
/// Unlocks last until the screen locks or 15 minutes pass.
@MainActor
final class ChatLock: ObservableObject {
    static let shared = ChatLock()
    static let enabledKey = "cookie.requireTouchID"

    @Published private(set) var unlockedAt: Date?
    private let window: TimeInterval = 15 * 60

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlockedAt = nil }
        }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var isLocked: Bool {
        guard enabled else { return false }
        guard let unlockedAt else { return true }
        return Date().timeIntervalSince(unlockedAt) > window
    }

    func unlock() {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your Cookie chats") { success, _ in
            DispatchQueue.main.async { if success { self.unlockedAt = Date() } }
        }
    }

    func lock() { unlockedAt = nil }
}
