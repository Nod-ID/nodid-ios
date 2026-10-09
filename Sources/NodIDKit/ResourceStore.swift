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
protocol ResourceFetcher {
    func fetch(_ url: URL, to file: URL, progress: @escaping (Int64) -> Void) async throws
}

struct ResourceStore {
    let directory: URL
    let baseURL: URL
    let pinnedManifestSHA256: String
    let fetcher: ResourceFetcher

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
        do { try await fetcher.fetch(baseURL.appendingPathComponent("manifest.json"), to: part, progress: { _ in }) } catch { throw ResourceError.network }
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
            try? fm.removeItem(at: tmp)
            let before = done
            do { try await fetcher.fetch(baseURL.appendingPathComponent(f.name), to: tmp, progress: { got in progress(Double(before + Int(got)) / Double(total)) }) }
            catch { throw ResourceError.network }
            guard (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int == f.size, try Self.sha256(of: tmp) == f.sha256 else {
                try? fm.removeItem(at: tmp); throw ResourceError.fileMismatch(f.name)
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

/// The real fetcher. `allowExpensive: false` keeps the early background start off mobile data.
struct URLSessionFetcher: ResourceFetcher {
    let allowExpensive: Bool
    func fetch(_ url: URL, to file: URL, progress: @escaping (Int64) -> Void) async throws {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.allowsExpensiveNetworkAccess = allowExpensive; c.timeoutIntervalForRequest = 30; c.waitsForConnectivity = false
        let session = URLSession(configuration: c)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ResourceError.network }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        progress((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0)
    }
}

/// Set by the release script (`scripts/sdk-resources.sh`) when it prepares a download release; nil in development builds.
enum PinnedResources {
    static let manifestSHA256: String? = "3dea3384f0461bfb8f44a7ee1f138b40a09a05daf69076be1fb8ed0c79ba1015"
    static let baseURL: URL? = URL(string: "https://github.com/Nod-ID/nodid-ios/releases/download/0.1.0/")
}
