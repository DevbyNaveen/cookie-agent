//
//  EnkeonAccount.swift
//  EnkeonVoiceKit (from Cookie's CookieAccount, cookie-harness 8ffefde)
//
//  Signing in to Enkeon: OAuth 2.1 with PKCE in the system browser, the way
//  Claude Code and Cursor connect (identity/src/oauth2_server.rs). The app
//  registers itself with a one-time loopback address, the person signs in and
//  picks a project on enkeon.com, and the tokens go to Enkeon's Keychain item.
//  The access token lasts an hour and is renewed here. No password ever
//  passes through the app.
//
//  Not yet: binding tokens to this Mac (DPoP, RFC 9449). The gateway doesn't
//  accept DPoP proofs, so a stolen token works elsewhere until it expires.
//

import AppKit
import CryptoKit
import Foundation
import Network

@MainActor
public final class EnkeonAccount: ObservableObject {
    public static let shared = EnkeonAccount()

    public enum Phase: Equatable {
        case signedOut
        case waitingForBrowser
        case signedIn
        case failed(String)
    }

    struct Tokens: Codable, Equatable, Sendable {
        let clientID: String
        let access: String
        let refresh: String
        let expires: Date
        /// The project picked on enkeon.com (nil from a gateway that doesn't say yet).
        var projectID: String?
        /// Its name (nil from a gateway that doesn't send it yet).
        var projectName: String?

        /// Renewed a minute and a half early, so a run never starts on a token about to lapse.
        func needsRefresh(now: Date = Date()) -> Bool { expires.timeIntervalSince(now) < 90 }
    }

    enum Callback: Equatable {
        case code(String)
        case refused
        case ignored
    }

    @Published public private(set) var phase: Phase = .signedOut

    static let issuer = URL(string: "https://api.thinkingroot.com")!
    /// Read your context (recall, search, branches) and save to it (remember): nothing else.
    static let scope = "recall remember search"

    /// The signed-in project, for its REST routes (approvals, meetings).
    public var projectID: String? { cachedTokens?.projectID }
    public var projectName: String? { cachedTokens?.projectName }
    nonisolated private static let keychainService = "com.enkeon.app.account"
    nonisolated private static let keychainAccount = "enkeon-oauth"
    private var cachedTokens: Tokens?

    private var signInTask: Task<Void, Never>?
    private var refreshing: Task<Tokens?, Never>?
    private var generation = UUID()

    private init() {
        let current = generation
        Task { [weak self] in
            let tokens = await Task.detached { Self.stored() }.value
            guard let self, self.generation == current else { return }
            self.cachedTokens = tokens
            self.phase = tokens == nil ? .signedOut : .signedIn
        }
    }

    public var isSignedIn: Bool { phase == .signedIn }

    // MARK: Sign in / out

    public func signIn() {
        signInTask?.cancel()
        refreshing?.cancel()
        refreshing = nil
        generation = UUID()
        let current = generation
        phase = .waitingForBrowser
        signInTask = Task {
            do {
                let tokens = try await Self.runSignIn()
                guard !Task.isCancelled, generation == current else { return }
                try Self.store(tokens)
                cachedTokens = tokens
                phase = .signedIn
            } catch is CancellationError {
                guard generation == current else { return }
                phase = cachedTokens == nil ? .signedOut : .signedIn
            } catch {
                guard generation == current else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelSignIn() {
        generation = UUID()
        signInTask?.cancel()
        signInTask = nil
        phase = cachedTokens == nil ? .signedOut : .signedIn
    }

    /// Forgets the tokens on this Mac. The gateway has no revocation endpoint
    /// yet, so the refresh token stays valid on the server until it expires.
    public func signOut() {
        generation = UUID()
        signInTask?.cancel()
        signInTask = nil
        refreshing?.cancel()
        refreshing = nil
        cachedTokens = nil
        EnkeonKeychain.delete(service: Self.keychainService, account: Self.keychainAccount)
        phase = .signedOut
    }

    /// A current access token, renewed if needed; nil when signed out or when
    /// renewing failed (a refused refresh signs out).
    public func accessToken() async -> String? {
        guard let tokens = cachedTokens else { return nil }
        guard tokens.needsRefresh() else { return tokens.access }
        if let refreshing { return await refreshing.value?.access }
        let current = generation
        let task = Task { () -> Tokens? in
            do {
                let renewed = try await Self.refresh(tokens)
                guard !Task.isCancelled, generation == current else { return nil }
                try Self.store(renewed)
                cachedTokens = renewed
                return renewed
            } catch let error as AccountError where error.signsOut {
                guard generation == current else { return nil }
                self.signOut()
                return nil
            } catch {
                return nil
            }
        }
        refreshing = task
        let renewed = await task.value
        guard generation == current else { return nil }
        refreshing = nil
        return renewed?.access
    }

    // MARK: The flow

    private static func runSignIn() async throws -> Tokens {
        let metadata = try await discover()
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)/callback"
        let clientID = try await register(metadata.registration, redirect: redirect)
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(16)
        NSWorkspace.shared.open(authorizeURL(endpoint: metadata.authorization, clientID: clientID,
                                             redirect: redirect, state: state, challenge: challenge(for: verifier)))
        let code = try await listener.awaitCode(state: state, timeout: 300)
        let response: TokenResponse = try await post(metadata.token, form: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "client_id": clientID,
        ])
        return response.tokens(clientID: clientID)
    }

    private static func refresh(_ tokens: Tokens) async throws -> Tokens {
        let metadata = try await discover()
        let response: TokenResponse = try await post(metadata.token, form: [
            "grant_type": "refresh_token", "refresh_token": tokens.refresh, "client_id": tokens.clientID,
        ])
        return response.tokens(clientID: tokens.clientID, keeping: tokens)
    }

    // MARK: Pieces (pure, checked by the interaction tests)

    /// S256: base64url(SHA-256(verifier)), no padding (RFC 7636 §4.2).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(data)
    }

    static func authorizeURL(endpoint: URL, clientID: String, redirect: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The browser's request to the loopback listener: a code with the right
    /// state, a refusal (wrong state, or the person said no), or something else.
    nonisolated static func callback(_ request: String, state: String) -> Callback {
        let requestLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])), components.path == "/callback" else { return .ignored }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["state"] == state, let code = query["code"], !code.isEmpty else { return .refused }
        return .code(code)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: HTTP

    private struct Metadata {
        let authorization: URL
        let token: URL
        let registration: URL
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String
        let project_id: String?
        let project_name: String?

        func tokens(clientID: String, keeping previous: Tokens? = nil) -> Tokens {
            Tokens(clientID: clientID, access: access_token, refresh: refresh_token, expires: Date().addingTimeInterval(expires_in),
                   projectID: project_id ?? previous?.projectID, projectName: project_name ?? previous?.projectName)
        }
    }

    struct AccountError: LocalizedError {
        let message: String
        /// The server refused the refresh token: it is gone, so sign out.
        var signsOut = false
        var errorDescription: String? { message }
    }

    private static func discover() async throws -> Metadata {
        struct Body: Decodable { let authorization_endpoint: URL; let token_endpoint: URL; let registration_endpoint: URL }
        let url = issuer.appendingPathComponent(".well-known/oauth-authorization-server")
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response, data, "reach Enkeon")
        let body = try JSONDecoder().decode(Body.self, from: data)
        return Metadata(authorization: body.authorization_endpoint, token: body.token_endpoint, registration: body.registration_endpoint)
    }

    private static func register(_ endpoint: URL, redirect: String) async throws -> String {
        struct Body: Decodable { let client_id: String }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "Enkeon", "redirect_uris": [redirect]])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data, "register this Mac with Enkeon")
        return try JSONDecoder().decode(Body.self, from: data).client_id
    }

    private static func post<T: Decodable>(_ endpoint: URL, form: [String: String]) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which a form decoder reads as a space.
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if form["grant_type"] == "refresh_token", (400...401).contains(status) {
            throw AccountError(message: "Your Enkeon sign-in ended. Sign in again in Connections.", signsOut: true)
        }
        try check(response, data, "finish signing in")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data, _ what: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw AccountError(message: "Couldn't \(what) (HTTP \(status)).")
        }
    }

    // MARK: Keychain

    nonisolated private static func stored() -> Tokens? {
        guard let data = try? EnkeonKeychain.read(service: keychainService, account: keychainAccount, interactive: false) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func store(_ tokens: Tokens) throws {
        try EnkeonKeychain.set(try JSONEncoder().encode(tokens), service: keychainService, account: keychainAccount)
    }
}

/// A one-time HTTP listener on 127.0.0.1 that waits for the browser to come
/// back with the authorization code (RFC 8252 §7.3).
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "enkeon.signin.loopback")
    let port: UInt16
    private var waiter: CheckedContinuation<String, Error>?
    private var state = ""

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "enkeon.signin.ready")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // The state handler runs on `queue` only; the flag keeps a second state from resuming twice.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let loopback = LoopbackListener(listener: listener, port: port)
        listener.newConnectionHandler = { [weak loopback] connection in loopback?.accept(connection) }
        return loopback
    }

    func awaitCode(state: String, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.sync {
                    self.state = state
                    self.waiter = continuation
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(EnkeonAccount.AccountError(message: "Sign-in timed out. Try again.")))
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let result = EnkeonAccount.callback(request, state: self.state)
            let page: String
            switch result {
            case .code: page = "You're signed in to Enkeon. You can close this tab."
            case .refused: page = "Enkeon wasn't signed in. You can close this tab and try again from the app."
            case .ignored: page = ""
            }
            let body = page.isEmpty ? "" : "<!doctype html><meta charset=utf-8><title>Enkeon</title><body style=\"font:15px -apple-system;margin:4em;text-align:center\">\(page)</body>"
            let status = page.isEmpty ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            switch result {
            case .code(let code): self.finish(.success(code))
            case .refused: self.finish(.failure(EnkeonAccount.AccountError(message: "Sign-in was cancelled or didn't match. Try again.")))
            case .ignored: break
            }
        }
    }

    /// Called on `queue` only.
    private func finish(_ result: Result<String, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }
}
