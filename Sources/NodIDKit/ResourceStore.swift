// The proving resources (circuits, verification keys, SRS, CSCA files; about 130 MB) as a one-time download instead of part of the host app.
// Rule 6 (pinned versions): the SDK carries the SHA-256 of the release's manifest (`PinnedResources`); the manifest lists every file with its size
// and SHA-256; nothing is used unless it matches, so the download host is trusted for delivery only, not for content. Plain Foundation and
// CryptoKit, so Tests/ResourceStoreCheck.swift runs on the Mac.
import Foundation
import CryptoKit

struct ResourceFile: Codable, Equatable { let name: String; let size: Int; let sha256: String }
struct ResourceManifest: Codable, Equatable { let version: String; let files: [ResourceFile] }

enum ResourceError: Error, Equatable {
    case notConfigured        // no pinned manifest hash in this SDK build (development builds use the bundle)
    case manifestMismatch     // the downloaded manifest is not the pinned one
    case badManifest
    case unsafeName(String)
    case fileMismatch(String) // wrong size or hash after download
    case network
}

/// Gets one URL into a file. The real one uses URLSession; the test one copies from a folder.
/// With `resume: true` and a partial file already there, it asks only for the rest. `progress` gets the bytes now in the file.
protocol ResourceFetcher {
    func fetch(_ url: URL, to file: URL, resume: Bool, progress: @escaping (Int64) -> Void) async throws
}

struct ResourceStore {
    let directory: URL
    let baseURL: URL
    let pinnedManifestSHA256: String
    let fetcher: ResourceFetcher
    /// Tried in order when `baseURL` cannot be reached. The pinned hashes are checked the same way whichever host answered.
    var fallbackURLs: [URL] = []

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var markerURL: URL { directory.appendingPathComponent(".verified") }

    /// A file name the manifest may use: no path parts, nothing hidden.
    static func safe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.contains("..") && name.count < 128
    }

    /// True when a previous run finished and every file is still there with the recorded size. Quick: no hashing.
    func isComplete() -> Bool {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8), marker == pinnedManifestSHA256,
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(ResourceManifest.self, from: data), sha256Hex(data) == pinnedManifestSHA256 else { return false }
        return m.files.allSatisfy { f in
            let a = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.name).path)
            return (a?[.size] as? Int) == f.size
        }
    }

    /// Fetches one file from the first host that answers. Stops at once when the task is cancelled.
    private func fetchAny(_ name: String, to file: URL, resume: Bool, progress: @escaping (Int64) -> Void) async throws {
        for base in [baseURL] + fallbackURLs {
            do { try await fetcher.fetch(base.appendingPathComponent(name), to: file, resume: resume, progress: progress); return }
            catch { if Task.isCancelled || error is CancellationError { throw CancellationError() } }
        }
        throw ResourceError.network
    }

    private func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Makes the folder complete and returns it. Files already there and correct are kept. `progress` is 0...1 over all the bytes still to get.
    @discardableResult
    func ensure(progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        if isComplete() { progress(1); return directory }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var ex = URLResourceValues(); ex.isExcludedFromBackup = true
        var dir = directory; try? dir.setResourceValues(ex)

        let manifestFile = directory.appendingPathComponent("manifest.json")
        let part = directory.appendingPathComponent("manifest.json.part")
        try? fm.removeItem(at: part)
        try await fetchAny("manifest.json", to: part, resume: false, progress: { _ in })
        guard try Self.sha256(of: part) == pinnedManifestSHA256 else { try? fm.removeItem(at: part); throw ResourceError.manifestMismatch }
        let manifestData = try Data(contentsOf: part)
        guard let manifest = try? JSONDecoder().decode(ResourceManifest.self, from: manifestData), !manifest.files.isEmpty else { throw ResourceError.badManifest }
        for f in manifest.files where !Self.safe(f.name) { throw ResourceError.unsafeName(f.name) }

        // What is missing or wrong (size first, then hash for files that look present).
        var todo: [ResourceFile] = []
        for f in manifest.files {
            let u = directory.appendingPathComponent(f.name)
            if let a = try? fm.attributesOfItem(atPath: u.path), (a[.size] as? Int) == f.size, (try? Self.sha256(of: u)) == f.sha256 { continue }
            todo.append(f)
        }
        let total = max(1, todo.reduce(0) { $0 + $1.size })
        var done = 0
        for f in todo {
            let target = directory.appendingPathComponent(f.name), tmp = directory.appendingPathComponent(f.name + ".part")
            // A partial file from an interrupted run is continued; if the finished file does not match, it is fetched again from the start, once.
            var attempt = 0
            while true {
                let resume = attempt == 0 && ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0) > 0
                if !resume { try? fm.removeItem(at: tmp) }
                let before = done
                try await fetchAny(f.name, to: tmp, resume: resume, progress: { got in progress(min(1, Double(before + Int(got)) / Double(total))) })
                if (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int == f.size, try Self.sha256(of: tmp) == f.sha256 { break }
                try? fm.removeItem(at: tmp)
                attempt += 1
                if attempt > 1 { throw ResourceError.fileMismatch(f.name) }
            }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tmp, to: target)
            done += f.size
            progress(Double(done) / Double(total))
        }
        try? fm.removeItem(at: manifestFile)
        try fm.moveItem(at: part, to: manifestFile)
        try pinnedManifestSHA256.write(to: markerURL, atomically: true, encoding: .utf8)   // last: a half-finished folder never looks complete
        progress(1)
        return directory
    }
}

/// The real fetcher. Streams to the file in chunks, so progress follows the bytes as they arrive, and a stopped download can continue
/// (HTTP Range) instead of starting again. `allowExpensive: false` keeps it off mobile data; `waitForConnectivity` makes it wait for Wi-Fi
/// instead of failing.
struct URLSessionFetcher: ResourceFetcher {
    let allowExpensive: Bool
    var waitForConnectivity = false

    func fetch(_ url: URL, to file: URL, resume: Bool, progress: @escaping (Int64) -> Void) async throws {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.allowsExpensiveNetworkAccess = allowExpensive; c.allowsConstrainedNetworkAccess = allowExpensive
        c.waitsForConnectivity = waitForConnectivity
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = waitForConnectivity ? 7 * 24 * 3600 : 3600
        let fm = FileManager.default
        var offset: Int64 = 0
        if resume, let n = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int64 { offset = n }
        if offset == 0 { try? fm.removeItem(at: file); guard fm.createFile(atPath: file.path, contents: nil) else { throw ResourceError.network } }
        let receiver = ChunkReceiver(file: file, offset: offset, progress: progress)
        let session = URLSession(configuration: c, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // byte offsets for resuming must match the bytes on disk
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                receiver.start(k); task.resume()
            }
        } onCancel: { task.cancel() }
    }
}

/// Writes the received chunks to the file and reports the size so far. Appends after a 206 answer, starts over after a 200.
private final class ChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL, progress: (Int64) -> Void
    private var offset: Int64
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var rangeSatisfied = false
    private var failed = false

    init(file: URL, offset: Int64, progress: @escaping (Int64) -> Void) { self.file = file; self.offset = offset; self.progress = progress }
    func start(_ k: CheckedContinuation<Void, Error>) { continuation = k }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { failed = true; completionHandler(.cancel); return }
        switch http.statusCode {
        case 206 where offset > 0:
            handle = try? FileHandle(forWritingTo: file); _ = try? handle?.seekToEnd()
        case 200:
            offset = 0   // the host ignored the Range request: start over
            handle = try? FileHandle(forWritingTo: file); try? handle?.truncate(atOffset: 0)
        case 416:
            rangeSatisfied = true; completionHandler(.cancel); return   // already have all of it: the caller checks size and hash
        default:
            failed = true; completionHandler(.cancel); return
        }
        if handle == nil { failed = true; completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failed = true; dataTask.cancel(); return }
        offset += Int64(data.count)
        progress(offset)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        let k = continuation; continuation = nil
        if rangeSatisfied { k?.resume(); return }
        if failed { k?.resume(throwing: ResourceError.network); return }
        if let e = error as? URLError, e.code == .cancelled { k?.resume(throwing: CancellationError()); return }
        if error != nil { k?.resume(throwing: ResourceError.network); return }
        k?.resume()
    }
}

/// Set by the release script (`scripts/sdk-resources.sh`) when it prepares a download release; nil in development builds.
enum PinnedResources {
    static let manifestSHA256: String? = "61049a81b393ab2eed8326de7ea24cf7a5904cb062aecc145935d83bec3600c9"
    static let baseURL: URL? = URL(string: "https://nodid.app/sdk/0.1.1/")
    static let fallbackURLs: [URL] = [URL(string: "https://github.com/Nod-ID/nodid-ios/releases/download/0.1.1/")!]
}
