//
//  CookieModelAsset.swift
//  Cookie
//
//  Real-looking models. When the person wants to see the real thing, the
//  model can hand build_model a USDZ file instead of a list of parts: a
//  freely licensed one from the web (fetched over HTTPS only, at most 50 MB,
//  in 20 seconds, written down in Proof) or one already in the person's home
//  folder. Cookie keeps fetched files under Application Support, by the
//  link's SHA-256, and fetches each only once; the folder stays under 500 MB
//  by letting go of the files used longest ago.
//
//  RealityKit opens the file. Cookie scales it to the size of a parts-library
//  model and centres it, so the camera, the light, the shadow and the label
//  rails work on it unchanged, and turns the file's named nodes into parts:
//  each top-level piece (which explodes on its own) and each named node
//  inside one, up to 64, named from the file (sanitised, never repeated).
//  Every part is its box in the scene, so the build check, beats, labels and
//  [VISUAL:…] verbs read a real model the way they read a built one. A file
//  whose nodes carry only generic names ("Mesh_0", "Object_12") still turns
//  and zooms, and the check says plainly that Cookie can't point at its parts.
//
//  Nothing in the file runs: RealityKit reads geometry and materials, and the
//  model only chooses the link, the title, labels and beats.
//

import CryptoKit
import Foundation
import RealityKit
import simd

enum CookieModelAsset {
    static let maxBytes = 50 * 1024 * 1024
    static let timeout: TimeInterval = 20
    /// Fetched models kept on this Mac, at most; the files used longest ago go first.
    static let cacheLimit = 500 * 1024 * 1024
    /// Parts surfaced from one file: the pieces first, then named nodes inside them, breadth first.
    static let maxParts = CookieScene.maxParts
    /// What a web link may point at, and what a file on this Mac may be.
    static let webExtensions: Set<String> = ["usdz"]
    static let fileExtensions: Set<String> = ["usdz", "usda", "usdc", "reality"]
    /// The radius a loaded model is scaled to: about the size of a model built from parts.
    static let radius: Float = 0.6

    /// Where fetched files live; checks point it somewhere else.
    static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/Models", isDirectory: true)
    /// The person's home: the only place a local model may be read from. Checks point it somewhere else.
    static var home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Where it comes from

    enum Source: Equatable {
        case web(URL)
        case file(URL)

        /// What the person is told the model came from: the site, or that it's their own file.
        var credit: String {
            switch self {
            case .web(let url): return url.host ?? url.absoluteString
            case .file(let url): return "your file \(url.lastPathComponent)"
            }
        }
    }

    /// Why a model couldn't be loaded, in words the model can act on and the person can hear.
    struct Failure: Error, Equatable {
        enum Kind: String { case address, tooBig = "too big", notModel = "not a model file", network, timeout, load, cancelled }
        let kind: Kind
        let message: String
        init(_ kind: Kind, _ message: String) {
            self.kind = kind
            self.message = message
        }
    }

    /// The asset field read strictly: an https link to a .usdz, or a model file inside the home folder that exists.
    static func source(_ raw: Any?) throws -> Source {
        guard let fields = raw as? [String: Any] else {
            throw Failure(.address, "scene.asset: must be {\"url\":\"https://….usdz\"} or {\"path\":\"~/….usdz\"}")
        }
        if let text = (fields["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .web(try webAddress(text))
        }
        if let text = (fields["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .file(try localFile(text))
        }
        throw Failure(.address, "scene.asset: give a url (https://….usdz) or a path (~/….usdz)")
    }

    static func webAddress(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw Failure(.address, "asset.url: \"\(text.prefix(80))\" isn't a link")
        }
        guard scheme == "https" else { throw Failure(.address, "asset.url: only https:// links are fetched, not \(scheme)://") }
        guard let host = url.host, !host.isEmpty else { throw Failure(.address, "asset.url: the link has no site in it") }
        guard url.user == nil, url.password == nil else { throw Failure(.address, "asset.url: a link carrying a user name or password isn't fetched") }
        guard webExtensions.contains(url.pathExtension.lowercased()) else {
            throw Failure(.notModel, "asset.url: \(url.lastPathComponent.isEmpty ? host : url.lastPathComponent) isn't a .usdz file; give a direct link to the .usdz, not a page that shows it")
        }
        return url
    }

    /// A path starting "~/" (or absolute), resolved through any links, that must land inside the home folder.
    static func localFile(_ text: String) throws -> URL {
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        let expanded = text == "~" ? homePath : text.hasPrefix("~/") ? homePath + "/" + text.dropFirst(2) : text
        guard expanded.hasPrefix("/") else { throw Failure(.address, "asset.path: give the whole path, starting ~/ or /") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(homePath + "/") else { throw Failure(.address, "asset.path: only files in your home folder are opened") }
        guard fileExtensions.contains(url.pathExtension.lowercased()) else {
            throw Failure(.notModel, "asset.path: \(url.lastPathComponent) isn't a .usdz, .usda, .usdc or .reality file")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw Failure(.address, "asset.path: there's no file at \(text)")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { throw Failure(.tooBig, "asset.path: \(megabytes(size)) MB, past the \(megabytes(maxBytes)) MB limit") }
        return url
    }

    static func megabytes(_ bytes: Int) -> String { String(format: bytes < 10 * 1024 * 1024 ? "%.1f" : "%.0f", Double(bytes) / 1_048_576) }

    // MARK: Fetching

    /// The file a link is kept in: the SHA-256 of the link, so the same link is fetched once.
    static func cacheFile(for url: URL, in folder: URL = folder) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest).appendingPathExtension("usdz")
    }

    /// A redirect is followed only to another https address.
    static func allowsRedirect(to url: URL?) -> Bool { url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false }

    /// What a server says it's sending: anything that is plainly a page, text, a picture or a film isn't a model.
    static func acceptable(contentType: String?) -> Bool {
        guard let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return true }
        if ["text/", "image/", "video/", "audio/", "font/"].contains(where: type.hasPrefix) { return false }
        return !["html", "json", "javascript", "xml"].contains(where: type.contains)
    }

    /// A USDZ is a zip: it starts "PK\u{3}\u{4}".
    static func looksLikeUSDZ(_ head: Data) -> Bool { head.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) }

    /// Keeps count while a file comes in, and stops it the moment it's not a model or is too big.
    struct Receiver {
        var limit = CookieModelAsset.maxBytes
        private(set) var received = 0
        private(set) var head = Data()

        /// The server's answer, before any of the file: its status, its type and the size it announces.
        func begin(status: Int, contentType: String?, expected: Int64) throws {
            guard (200..<300).contains(status) else { throw Failure(.network, "the server answered \(status)\(status == 404 ? " (no file there)" : ""), so nothing was fetched") }
            guard acceptable(contentType: contentType) else {
                throw Failure(.notModel, "the link sends \(contentType ?? "something") rather than a .usdz file; give a direct link to the file")
            }
            if expected > Int64(limit) { throw Failure(.tooBig, "it's \(megabytes(Int(expected))) MB, past the \(megabytes(limit)) MB limit, so it wasn't fetched") }
        }

        /// One chunk arriving; past the limit the fetch stops there.
        mutating func add(_ chunk: Data) throws {
            received += chunk.count
            if head.count < 4 { head.append(chunk.prefix(4 - head.count)) }
            if received > limit { throw Failure(.tooBig, "it passed \(megabytes(limit)) MB while downloading, so Cookie stopped and kept nothing") }
        }

        /// The whole file is in: it must be a USDZ.
        func finish() throws {
            guard received > 0 else { throw Failure(.notModel, "the link sent an empty file") }
            guard looksLikeUSDZ(head) else { throw Failure(.notModel, "what came back isn't a USDZ file (it doesn't open as one)") }
        }
    }

    /// The file for a link: the kept copy when there is one (and it's marked as just used), else fetched
    /// into place. Throws a `Failure` saying plainly why not.
    static func fetch(_ url: URL, into folder: URL = folder) async throws -> (file: URL, bytes: Int, reused: Bool) {
        let file = cacheFile(for: url, in: folder)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return (file, size, true)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure(.load, "couldn't make the models folder (\(error.localizedDescription))")
        }
        let part = folder.appendingPathComponent("." + file.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)
        do {
            let bytes = try await CookieModelDownload.run(url, to: part, timeout: timeout)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: part, to: file)
            evict(folder, limit: cacheLimit, keeping: file)
            return (file, bytes, false)
        } catch let failure as Failure {
            try? FileManager.default.removeItem(at: part)
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Failure(.load, "couldn't keep the file (\(error.localizedDescription))")
        }
    }

    /// Lets go of the files used longest ago until the folder is under `limit` (never `keeping`).
    static func evict(_ folder: URL, limit: Int, keeping: URL?) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var kept = files.filter { $0.pathExtension == "usdz" }.map { file -> (url: URL, size: Int, used: Date) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.used < $1.used }
        var total = kept.reduce(0) { $0 + $1.size }
        while total > limit, let oldest = kept.first(where: { $0.url.standardizedFileURL != keeping?.standardizedFileURL }) {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            kept.removeAll { $0.url == oldest.url }
        }
    }

    /// `work`, or the failure when it takes longer than `seconds` (the work is cancelled).
    static func within<T: Sendable>(_ seconds: TimeInterval, _ failure: Failure, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw failure
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw failure }
            return first
        }
    }

    // MARK: Reading the file

    /// Names that say nothing about the part: exporters' defaults ("Mesh_0", "Object_12", "polySurface3").
    static let genericNames: Set<String> = [
        "mesh", "meshes", "node", "nodes", "geom", "geo", "geometry", "object", "obj", "group", "grp", "xform",
        "transform", "root", "rootnode", "scene", "world", "default", "defaultprim", "model", "models", "component",
        "components", "primitive", "prim", "polysurface", "pcube", "psphere", "pcylinder", "pplane", "cube", "sphere",
        "cylinder", "plane", "cone", "torus", "usdprimitiveaxis", "sketchfabmodel", "gltfscenerootnode", "gltfnode",
        "material", "materials", "looks", "shape", "shapes", "null", "empty", "armature", "skeleton", "part", "parts",
        "instance", "proto", "prototype", "collada", "fbx", "submesh",
    ]

    /// Whether a node's name says what the part is.
    static func meaningful(_ name: String) -> Bool {
        let letters = CookieScene.fold(name)
        return letters.count >= 2 && !genericNames.contains(letters)
    }

    /// One part found in a file: where its node is (child indices from the file's root), its box in the
    /// scaled, centred model, and the top-level piece it belongs to.
    struct Node: Equatable {
        let id: String
        let name: String
        let path: [Int]
        let centre: SIMD3<Float>
        let size: SIMD3<Float>
        let piece: String
        /// Named in the file (else a piece named "piece-N" by Cookie).
        let named: Bool
    }

    struct Discovery: Equatable {
        let nodes: [Node]
        /// Scale and centre (in the file's units) that bring the model to `radius` about the origin.
        let scale: Float
        let centre: SIMD3<Float>
        /// Named nodes the file had, including any past the cap.
        let namedFound: Int
        var pieces: [Node] { nodes.filter { $0.piece == $0.id } }
        var named: [Node] { nodes.filter(\.named) }
    }

    /// The parts of a loaded file; nil when it has nothing to draw.
    @MainActor
    static func discover(_ root: Entity) -> Discovery? {
        let whole = root.visualBounds(relativeTo: root)
        guard !whole.isEmpty, simd_reduce_max(whole.extents) > 0, whole.extents.x.isFinite, whole.extents.y.isFinite, whole.extents.z.isFinite else { return nil }
        let centre = whole.center
        let scale = radius / max(1e-6, simd_length(whole.extents) / 2)
        var taken = Set<String>()
        func id(for name: String, fallback: String) -> String {
            var base = meaningful(name) ? CookieModelShelf.slug(name) : fallback
            base = String(base.prefix(CookieScene.labelLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if base.isEmpty { base = fallback }
            var candidate = base, number = 2
            while taken.contains(candidate) { candidate = "\(base)-\(number)"; number += 1 }
            taken.insert(candidate)
            return candidate
        }
        func node(_ entity: Entity, path: [Int], piece: String?, fallback: String) -> Node? {
            let box = entity.visualBounds(relativeTo: root)
            guard !box.isEmpty else { return nil }
            let named = meaningful(entity.name)
            let own = id(for: entity.name, fallback: fallback)
            return Node(id: own, name: entity.name, path: path, centre: (box.center - centre) * scale,
                        size: simd_max(box.extents * scale, SIMD3(repeating: CookieScene.minSize)), piece: piece ?? own, named: named)
        }

        // The pieces: the children of the first node that branches (exporters wrap a model in single-child roots).
        var split = root, splitPath: [Int] = []
        while split.children.count == 1 {
            split = split.children[0]
            splitPath.append(0)
        }
        var nodes: [Node] = []
        var queue: [(entity: Entity, path: [Int], piece: String)] = []
        if split.children.isEmpty {
            if let only = node(split, path: splitPath, piece: nil, fallback: "model") { nodes.append(only) }
        } else {
            for (index, child) in split.children.enumerated() where nodes.count < maxParts {
                guard let piece = node(child, path: splitPath + [index], piece: nil, fallback: "piece-\(nodes.count + 1)") else { continue }
                nodes.append(piece)
                queue.append((child, splitPath + [index], piece.id))
            }
        }
        // Named nodes inside the pieces, breadth first, so the bigger parts come before their details.
        var namedFound = nodes.filter(\.named).count
        var head = 0
        while head < queue.count {
            let (entity, path, piece) = queue[head]
            head += 1
            for (index, child) in entity.children.enumerated() {
                let childPath = path + [index]
                queue.append((child, childPath, piece))
                guard meaningful(child.name), !child.visualBounds(relativeTo: root).isEmpty else { continue }
                namedFound += 1
                if nodes.count < maxParts, let found = node(child, path: childPath, piece: piece, fallback: "part") { nodes.append(found) }
            }
        }
        guard !nodes.isEmpty else { return nil }
        return Discovery(nodes: nodes, scale: scale, centre: centre, namedFound: namedFound)
    }

    /// The entity at `path` below `root`, if the file still has it.
    @MainActor
    static func entity(at path: [Int], in root: Entity) -> Entity? {
        var entity = root
        for index in path {
            guard index < entity.children.count else { return nil }
            entity = entity.children[index]
        }
        return entity
    }
}

// MARK: - Loaded files

/// The files RealityKit has opened, kept so a model built this turn shows without opening it again.
/// A stage shows a copy; the three used last stay open.
@MainActor
final class CookieModelAssets {
    static let shared = CookieModelAssets()
    static let kept = 3
    private var loaded: [(file: URL, entity: Entity)] = []

    func prototype(_ file: URL) async throws -> Entity {
        if let index = loaded.firstIndex(where: { $0.file == file }) {
            let hit = loaded.remove(at: index)
            loaded.append(hit)
            return hit.entity
        }
        let entity: Entity
        do {
            entity = try await CookieModelAsset.within(CookieModelAsset.timeout, .init(.timeout, "opening it took longer than \(Int(CookieModelAsset.timeout)) s")) {
                try await Entity(contentsOf: file)
            }
        } catch let failure as CookieModelAsset.Failure {
            throw failure
        } catch is CancellationError {
            throw CookieModelAsset.Failure(.cancelled, "stopped before it opened")
        } catch {
            throw CookieModelAsset.Failure(.load, "RealityKit couldn't open it as a 3D model (\(error.localizedDescription))")
        }
        loaded.append((file, entity))
        if loaded.count > Self.kept { loaded.removeFirst(loaded.count - Self.kept) }
        return entity
    }

    /// A fresh copy of a file opened earlier, for a stage to show; nil when it was let go.
    func copy(_ file: URL) -> Entity? {
        loaded.first { $0.file == file }?.entity.clone(recursive: true)
    }
}

// MARK: - Downloading

/// One fetch, streamed to a file: redirects only to https, the server's type and size checked before the
/// file, every chunk counted against the limit, stopped at once past it or when the turn is cancelled.
final class CookieModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Everything below runs on this queue, one callback at a time.
    private let queue = DispatchQueue(label: "cookie.model.download")
    private let part: URL
    private var receiver = CookieModelAsset.Receiver()
    private var handle: FileHandle?
    private var failure: CookieModelAsset.Failure?
    private var continuation: CheckedContinuation<Int, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(part: URL) {
        self.part = part
    }

    static func run(_ url: URL, to part: URL, timeout: TimeInterval) async throws -> Int {
        let download = CookieModelDownload(part: part)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.queue.async { download.start(url, timeout: timeout, continuation) }
            }
        } onCancel: {
            download.queue.async { download.stop(.init(.cancelled, "stopped before it finished downloading")) }
        }
    }

    private func start(_ url: URL, timeout: TimeInterval, _ continuation: CheckedContinuation<Int, Error>) {
        self.continuation = continuation
        guard !cancelled else { return finish(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
        var request = URLRequest(url: url)
        request.setValue("model/vnd.usdz+zip, application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private func stop(_ reason: CookieModelAsset.Failure) {
        cancelled = true
        if failure == nil { failure = reason }
        if let task { task.cancel() } else if continuation != nil { finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard CookieModelAsset.allowsRedirect(to: request.url) else {
            failure = .init(.address, "the link redirects to \(request.url?.scheme ?? "a non")://, which isn't HTTPS, so it wasn't followed")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A refused redirect arrives here as its own 3xx answer: the refusal already says why.
        guard failure == nil else { return completionHandler(.cancel) }
        let http = response as? HTTPURLResponse
        do {
            guard CookieModelAsset.allowsRedirect(to: response.url) else { throw CookieModelAsset.Failure(.address, "the file came from an address that isn't HTTPS") }
            try receiver.begin(status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType,
                               expected: response.expectedContentLength)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            handle = try FileHandle(forWritingTo: part)
            completionHandler(.allow)
        } catch {
            failure = error as? CookieModelAsset.Failure ?? .init(.load, "couldn't start the file (\(error.localizedDescription))")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try receiver.add(data)
            try handle?.write(contentsOf: data)
        } catch {
            failure = error as? CookieModelAsset.Failure ?? .init(.load, "couldn't write the file (\(error.localizedDescription))")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        try? handle?.close()
        handle = nil
        guard let continuation else { return }
        self.continuation = nil
        if let failure { return continuation.resume(throwing: failure) }
        if let error { return continuation.resume(throwing: Self.failure(error)) }
        do {
            try receiver.finish()
            continuation.resume(returning: receiver.received)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    /// A network error in plain words.
    static func failure(_ error: Error) -> CookieModelAsset.Failure {
        guard let error = error as? URLError else { return .init(.network, "the download failed (\(error.localizedDescription))") }
        switch error.code {
        case .timedOut: return .init(.timeout, "the download took longer than \(Int(CookieModelAsset.timeout)) s, so Cookie stopped")
        case .cancelled: return .init(.cancelled, "stopped before it finished downloading")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .init(.network, "this Mac looks offline, so the model couldn't be fetched")
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return .init(.network, "couldn't reach \(error.failingURL?.host ?? "the site")")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return .init(.network, "the site's secure connection couldn't be trusted")
        default: return .init(.network, "the download failed (\(error.localizedDescription))")
        }
    }
}

// MARK: - The scene a file makes

extension CookieScene {
    /// A model loaded from a file: where the file is, how it's scaled and centred into the scene, and which
    /// node of it each part is.
    struct Asset: Equatable {
        let file: URL
        /// Who to credit: the site it came from, or the person's own file.
        let credit: String
        let scale: Float
        /// The file's centre, in its own units.
        let centre: SIMD3<Float>
        /// Child indices from the file's root to each part's node.
        let paths: [String: [Int]]
        /// The parts that explode on their own, in order.
        let pieces: [String]
        /// Some part is named in the file, so Cookie can point at what it is.
        let pointable: Bool
    }

    /// A scene for a loaded file: its parts are the file's pieces and named nodes; the title, labels, beats
    /// and flows come from the model's scene JSON. Read as forgivingly as a built scene.
    static func read(asset fields: [String: Any], discovery: CookieModelAsset.Discovery, file: URL, credit: String) -> Reading {
        var reader = SceneReader()
        let scene = reader.assetScene(fields, discovery: discovery, file: file, credit: credit)
        return Reading(scene: scene, repairs: reader.repairs, errors: reader.errors)
    }
}

extension SceneReader {
    static let assetFields: Set<String> = ["title", "asset", "labels", "beats", "flows", "explode", "spin", "run"]

    mutating func assetScene(_ fields: [String: Any], discovery: CookieModelAsset.Discovery, file: URL, credit: String) -> Scene? {
        for key in fields.keys.sorted() where !Self.assetFields.contains(key) {
            repairs.append(["parts", "joints", "drives", "links"].contains(key)
                ? "scene.\(key): a loaded model's parts and how they hang together come from its file; ignored"
                : "scene.\(key): not a field for a loaded model; ignored")
        }
        var title = (fields["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            title = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            if title.count > 40 || title.allSatisfy({ $0.isHexDigit }) { title = "Model" }
            repairs.append("scene.title: missing; used \"\(title)\"")
        }
        title = shortened(title, to: Scene.titleLength, at: "scene.title")

        // Labels: node names (as in the file, or their ids) to the few words shown for them.
        var labels: [String: String] = [:]
        if let raw = fields["labels"] {
            if let given = raw as? [String: Any] {
                for key in given.keys.sorted() {
                    guard let words = text(given[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else {
                        repairs.append("labels.\(key): not words; ignored"); continue
                    }
                    let node = discovery.nodes.first { $0.name == key || $0.id == key }
                        ?? discovery.nodes.first { Scene.fold($0.name) == Scene.fold(key) || Scene.fold($0.id) == Scene.fold(key) }
                    guard let node, !Scene.fold(key).isEmpty else {
                        repairs.append("labels.\(key): no part by that name; ignored (parts: \(discovery.nodes.prefix(12).map(\.id).joined(separator: ", ")))"); continue
                    }
                    labels[node.id] = shortened(words, to: Scene.labelLength, at: "labels.\(key)")
                }
            } else {
                errors.append("scene.labels: must be an object {\"node name\":\"label\"}; left out")
            }
        }

        let parts = discovery.nodes.map { node in
            Scene.Part(id: node.id, label: labels[node.id],
                       form: Scene.Form(.box, ["width": node.size.x, "height": node.size.y, "depth": node.size.z]),
                       position: node.centre, rotation: .zero, tint: .steel, cut: false, group: node.piece)
        }
        let motion = motion(fields.filter { $0.key == "flows" }, parts: parts)
        let shell = Scene(title: "", parts: parts, explode: false, spin: false, flows: motion.flows)
        let asset = Scene.Asset(file: file, credit: credit, scale: discovery.scale, centre: discovery.centre,
                                paths: Dictionary(discovery.nodes.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a }),
                                pieces: discovery.pieces.map(\.id), pointable: !discovery.named.isEmpty)
        return Scene(title: title, parts: parts, explode: flag(fields["explode"], at: "scene.explode"), spin: flag(fields["spin"], at: "scene.spin"),
                     flows: motion.flows, run: flag(fields["run"], at: "scene.run"), beats: readBeats(fields["beats"], shell), asset: asset)
    }
}
