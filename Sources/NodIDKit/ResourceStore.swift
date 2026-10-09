// The proving resources (circuits, verification keys, SRS, CSCA files; about 135 MB in all, about 40 MB for one passport) as a one-time download instead of part of the host app.
// Rule 6 (pinned versions): the SDK carries the SHA-256 of the release's manifest (`PinnedResources`); the manifest lists every file with its size
// and SHA-256; nothing is used unless it matches, so the download host is trusted for delivery only, not for content. Plain Foundation and
// CryptoKit, so Tests/ResourceStoreCheck.swift runs on the Mac.
import Foundation
import CryptoKit

/// Opt-in progress trace for test apps (stage names, file names of the shared files, byte counts). Off unless a host sets `sink`. Never carries passport data.
enum NodTrace {
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    static func log(_ s: @autoclosure () -> String) { sink?(s()) }
}

/// `tier` groups the files: "base" (shared by every passport: the SRS, keys, CSCA data), "common" (the circuits most passports need, fetched ahead of time
/// by `NodID.prefetch`), "extra" (the other circuits, fetched only when a passport needs one). No tier means "base".
struct ResourceFile: Codable, Equatable { let name: String; let size: Int; let sha256: String; var tier: String? = nil }
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

    /// A file name the manifest may use: no path parts, nothing hidden.
    static func safe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.contains("..") && name.count < 128
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// The manifest on disk, if it is the pinned one.
    private func localManifest() -> ResourceManifest? {
        guard let data = try? Data(contentsOf: manifestURL), sha256Hex(data) == pinnedManifestSHA256 else { return nil }
        return try? JSONDecoder().decode(ResourceManifest.self, from: data)
    }

    /// Which files a call is about: everything (no arguments), whole tiers, and/or named files.
    private func selected(_ m: ResourceManifest, tiers: Set<String>?, names: Set<String>) -> [ResourceFile] {
        if tiers == nil && names.isEmpty { return m.files }
        return m.files.filter { names.contains($0.name) || (tiers?.contains($0.tier ?? "base") ?? false) }
    }

    /// True when the pinned manifest is on disk and every selected file is there with the recorded size. Quick: no hashing.
    /// (A file only gets its final name after its hash was checked.)
    func isComplete(tiers: Set<String>? = nil, names: Set<String> = []) -> Bool {
        guard let m = localManifest(), names.isSubset(of: Set(m.files.map(\.name))) else { return false }   // a name that is not listed is never "complete"
        return selected(m, tiers: tiers, names: names).allSatisfy { f in
            let a = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.name).path)
            return (a?[.size] as? Int) == f.size
        }
    }

    private func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Makes the selected files complete and returns the folder. Files already there and correct are kept. Up to `parallel` files download at once.
    /// `progress` is 0...1 over all the bytes still to get. A name the manifest does not list is an error (`badManifest`).
    @discardableResult
    func ensure(tiers: Set<String>? = nil, names: Set<String> = [], parallel: Int = 4, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        if isComplete(tiers: tiers, names: names) { progress(1); return directory }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var ex = URLResourceValues(); ex.isExcludedFromBackup = true
        var dir = directory; try? dir.setResourceValues(ex)

        var manifest = localManifest()
        if manifest == nil {
            let part = directory.appendingPathComponent("manifest.json.part")
            try? fm.removeItem(at: part)
            try await fetchAny("manifest.json", to: part, resume: false, progress: { _ in })
            guard try Self.sha256(of: part) == pinnedManifestSHA256 else { try? fm.removeItem(at: part); throw ResourceError.manifestMismatch }
            let manifestData = try Data(contentsOf: part)
            guard let m = try? JSONDecoder().decode(ResourceManifest.self, from: manifestData), !m.files.isEmpty else { throw ResourceError.badManifest }
            for f in m.files where !Self.safe(f.name) { throw ResourceError.unsafeName(f.name) }
            try? fm.removeItem(at: manifestURL)
            try fm.moveItem(at: part, to: manifestURL)    // verified against the pin, so it can stay
            manifest = m
        }
        guard let m = manifest else { throw ResourceError.badManifest }
        let known = Set(m.files.map(\.name))
        for n in names where !known.contains(n) { throw ResourceError.badManifest }

        // What is missing or wrong (size first, then hash for files that look present). Biggest first, so the long download starts early.
        var todo: [ResourceFile] = []
        for f in selected(m, tiers: tiers, names: names) {
            let u = directory.appendingPathComponent(f.name)
            if let a = try? fm.attributesOfItem(atPath: u.path), (a[.size] as? Int) == f.size, (try? Self.sha256(of: u)) == f.sha256 { continue }
            todo.append(f)
        }
        todo.sort { $0.size > $1.size }
        let total = max(1, todo.reduce(0) { $0 + $1.size })
        NodTrace.log("ensure: \(todo.count) files, \(total) bytes to get (parallel \(parallel))")
        let counter = ByteCounter(total: total, report: progress)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                guard next < todo.count else { return }
                let f = todo[next]; next += 1
                group.addTask { try await self.fetchFile(f, counter: counter) }
            }
            for _ in 0..<max(1, min(parallel, todo.count)) { launch() }
            while try await group.next() != nil { launch() }
        }
        progress(1)
        return directory
    }

    /// One file: continue a partial one, check size and hash, move it into place. A bad finished file is fetched again from the start, once.
    private func fetchFile(_ f: ResourceFile, counter: ByteCounter) async throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(f.name), tmp = directory.appendingPathComponent(f.name + ".part")
        var attempt = 0
        NodTrace.log("file start \(f.name) \(f.size) B")
        while true {
            let resume = attempt == 0 && ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0) > 0
            if !resume { try? fm.removeItem(at: tmp) }
            try await fetchAny(f.name, to: tmp, resume: resume, progress: { got in counter.set(f.name, min(Int(got), f.size)) })
            if (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int == f.size, try Self.sha256(of: tmp) == f.sha256 { break }
            try? fm.removeItem(at: tmp)
            counter.set(f.name, 0)
            attempt += 1
            if attempt > 1 { throw ResourceError.fileMismatch(f.name) }
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        counter.set(f.name, f.size)
        NodTrace.log("file done \(f.name)")
    }

    /// Fetches one file from the first host that answers. Stops at once when the task is cancelled.
    private func fetchAny(_ name: String, to file: URL, resume: Bool, progress: @escaping (Int64) -> Void) async throws {
        for base in [baseURL] + fallbackURLs {
            do { try await fetcher.fetch(base.appendingPathComponent(name), to: file, resume: resume, progress: progress); return }
            catch { NodTrace.log("fetch \(name) from \(base.host ?? "?") failed: \(error)"); if Task.isCancelled || error is CancellationError { throw CancellationError() } }
        }
        throw ResourceError.network
    }

}

/// Bytes received so far per file, summed into one progress number. Safe to call from several downloads at once.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var got: [String: Int] = [:]
    private let total: Int, report: (Double) -> Void
    init(total: Int, report: @escaping (Double) -> Void) { self.total = total; self.report = report }
    func set(_ name: String, _ bytes: Int) {
        lock.lock(); got[name] = bytes; let sum = got.values.reduce(0, +); lock.unlock()
        report(min(1, Double(sum) / Double(total)))
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
    static let manifestSHA256: String? = "c0075de1a8b3777ad264d2f94a2b1000d1f5e10010f060c9bb1750f9fbc54142"
    static let baseURL: URL? = URL(string: "https://nodid.app/sdk/0.1.3/")
    static let fallbackURLs: [URL] = [URL(string: "https://github.com/Nod-ID/nodid-ios/releases/download/0.1.3/")!]
}
