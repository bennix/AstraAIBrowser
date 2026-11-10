import Foundation
import CryptoKit

/// Immutable resource identities keep resume files and playlist ordering aligned.
struct HLSResource: Hashable, Sendable {
    let url: URL
    let range: Range<Int64>?
}

struct HLSSegment: Sendable {
    let sequence: Int64
    let start: Double
    let duration: Double
    let resource: HLSResource
    let key: HLSResource?
    let iv: String?
    let map: HLSResource?
    let discontinuity: Bool
}

struct HLSManifest: Sendable {
    struct Variant: Sendable {
        let url: URL
        let height: Int
        let bandwidth: Int
    }
    enum Failure: Error { case malformed, unsupported }
    let variants: [Variant]
    let segments: [HLSSegment]
    let live: Bool
    let targetDuration: Double

    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var token = ""
        var quoted = false
        func consume() {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            token = ""
        }
        for character in line[line.index(after: colon)...] {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { consume() } else { token.append(character) }
        }
        consume()
        return result
    }

    static func parse(_ text: String, base: URL) throws -> HLSManifest {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw Failure.malformed }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var variants: [Variant] = []
        var segments: [HLSSegment] = []
        var pendingVariant: [String: String]?
        var duration: Double?
        var target = 0.0
        var sequence: Int64 = 0
        var elapsed = 0.0
        var rangeText: String?
        var previous: HLSResource?
        var key: HLSResource?
        var iv: String?
        var map: HLSResource?
        var discontinuity = false
        func resource(_ value: String, range: String? = nil, previous: HLSResource? = nil) throws -> HLSResource {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.malformed }
            guard let range else { return HLSResource(url: url, range: nil) }
            let parts = range.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count <= 2, let count = Int64(parts[0]), count > 0 else { throw Failure.malformed }
            let offset = parts.count == 2 ? Int64(parts[1]) : (previous?.url == url ? previous?.range?.upperBound : nil)
            guard let offset, offset >= 0, offset <= Int64.max - count else { throw Failure.malformed }
            return HLSResource(url: url, range: offset..<(offset + count))
        }
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-PART:") || line.hasPrefix("#EXT-X-SKIP:") || line == "#EXT-X-GAP" {
                throw Failure.unsupported
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(line)
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Double(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let value = Int64(line.dropFirst(22)), value >= 0 else { throw Failure.malformed }
                sequence = value
            } else if line.hasPrefix("#EXTINF:") {
                duration = line.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                rangeText = String(line.dropFirst(17))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let values = attributes(line)
                if values["METHOD"] == "NONE" { key = nil; iv = nil; continue }
                guard map == nil, values["METHOD"] == "AES-128", values["KEYFORMAT", default: "identity"] == "identity",
                      let uri = values["URI"] else { throw Failure.unsupported }
                key = try resource(uri)
                iv = values["IV"]
                if let explicitIV = iv {
                    let digits = explicitIV.dropFirst(2)
                    guard explicitIV.hasPrefix("0x"), !digits.isEmpty, digits.count <= 32,
                          digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw Failure.malformed }
                    iv = "0x" + String(repeating: "0", count: 32 - digits.count) + digits
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let values = attributes(line)
                // Encrypted initialization sections require separate key/IV state.
                guard key == nil, let uri = values["URI"] else { throw Failure.unsupported }
                map = try resource(uri, range: values["BYTERANGE"], previous: map)
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if !line.hasPrefix("#") {
                if let values = pendingVariant {
                    let height = values["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0
                    variants.append(Variant(url: try resource(line).url, height: height, bandwidth: Int(values["BANDWIDTH"] ?? "") ?? 0))
                    pendingVariant = nil
                    continue
                }
                guard let segmentDuration = duration, segmentDuration.isFinite, segmentDuration > 0,
                      sequence < Int64.max else { throw Failure.malformed }
                let chunk = try resource(line, range: rangeText, previous: previous)
                segments.append(HLSSegment(sequence: sequence, start: elapsed, duration: segmentDuration,
                    resource: chunk, key: key, iv: iv, map: map, discontinuity: discontinuity))
                previous = chunk
                sequence += 1
                elapsed += segmentDuration
                duration = nil
                rangeText = nil
                discontinuity = false
            }
        }
        guard !variants.isEmpty || (!segments.isEmpty && target.isFinite && target > 0),
              duration == nil, pendingVariant == nil else { throw Failure.malformed }
        return HLSManifest(variants: variants, segments: segments, live: !lines.contains("#EXT-X-ENDLIST"), targetDuration: target)
    }

    var cacheIdentity: String {
        let description = segments.map {
            "\($0.sequence)|\($0.start)|\($0.duration)|\($0.resource)|\(String(describing: $0.key))|\($0.iv ?? "")|\(String(describing: $0.map))"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(description.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func selected(start: Double, end: Double?) -> [HLSSegment] {
        segments.filter { $0.start + $0.duration > start && $0.start < (end ?? .infinity) }
    }

    /// Source-sequence ownership removes overlap without relying on timestamp guesses.
    static func partitions(_ segments: [HLSSegment], count: Int) -> [[HLSSegment]] {
        guard !segments.isEmpty else { return [] }
        let count = min(max(1, count), min(16, segments.count))
        let firstTime = segments[0].start
        let lastTime = segments.last!.start + segments.last!.duration
        let interval = (lastTime - firstTime) / Double(count)
        var groups = Array(repeating: [HLSSegment](), count: count)
        for segment in segments {
            let index = min(count - 1, Int((segment.start - firstTime) / interval))
            groups[index].append(segment)
        }
        return groups.filter { !$0.isEmpty }
    }

    func localPlaylist(segments: [HLSSegment], files: [HLSResource: String]) throws -> String {
        guard let first = segments.first else { throw Failure.malformed }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(ceil(targetDuration)))",
                     "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)", "#EXT-X-PLAYLIST-TYPE:VOD"]
        func path(_ resource: HLSResource) throws -> String {
            guard let name = files[resource], !name.contains("\""), !name.contains("\n") else { throw Failure.malformed }
            return name
        }
        for segment in segments {
            if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if let key = segment.key {
                let iv = segment.iv ?? String(format: "0x%032llx", segment.sequence)
                lines.append("#EXT-X-KEY:METHOD=AES-128,URI=\"\(try path(key))\",IV=\(iv)")
            } else { lines.append("#EXT-X-KEY:METHOD=NONE") }
            if let map = segment.map { lines.append("#EXT-X-MAP:URI=\"\(try path(map))\"") }
            lines.append("#EXTINF:\(segment.duration),")
            lines.append(try path(segment.resource))
        }
        return (lines + ["#EXT-X-ENDLIST", ""]).joined(separator: "\n")
    }
}

@MainActor
final class HLSDownloadOperation {
    private let session: APIClient.MediaSession
    private let provider: MediaSessionCookieProviding?
    private let pageURL: URL
    private let userAgent: String?
    private let headers: [String: String]
    private var keyFiles = Set<URL>()
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused = false
    private var cancelled = false

    init(pageURL: URL, userAgent: String?, provider: MediaSessionCookieProviding?, proxy: String?, headers: [String: String] = [:]) {
        self.pageURL = pageURL
        self.userAgent = userAgent
        self.provider = provider
        self.headers = headers
        session = APIClient.MediaSession(proxy: proxy)
    }

    func pause() { paused = true }
    func resume() {
        paused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func cancel() { cancelled = true; resume(); session.close() }
    func close() {
        session.close()
        let files = keyFiles
        keyFiles.removeAll()
        Task.detached { for file in files { try? FileManager.default.removeItem(at: file) } }
    }

    private func checkpoint() async throws {
        if paused && !cancelled { await withCheckedContinuation { pauseWaiters.append($0) } }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    func resolve(_ url: URL, maximumHeight: Int?, depth: Int = 0) async throws -> HLSManifest {
        guard depth < 8 else { throw HLSManifest.Failure.malformed }
        try await checkpoint()
        let (data, finalURL) = try await session.resource(HLSResource(url: url, range: nil), pageURL: pageURL,
                                                       userAgent: userAgent, provider: provider, headers: headers)
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw HLSManifest.Failure.malformed }
        let manifest = try HLSManifest.parse(text, base: finalURL)
        guard !manifest.variants.isEmpty else { return manifest }
        let sorted = manifest.variants.sorted { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
        let candidate = sorted.last(where: { $0.height <= (maximumHeight ?? Int.max) }) ?? sorted[0]
        return try await resolve(candidate.url, maximumHeight: maximumHeight, depth: depth + 1)
    }

    func download(_ plan: HLSManifest, segments: [HLSSegment], directory: URL,
                  partitions: Int, progress: @escaping @MainActor (Int64, Int, Int64) -> Void) async throws -> URL {
        guard !plan.live, !segments.isEmpty, segments.count <= 4000 else { throw HLSManifest.Failure.unsupported }
        let chunks = HLSManifest.partitions(segments, count: partitions)
        var resources: [HLSResource] = []
        var seen = Set<HLSResource>()
        // Interleave temporal partitions while assigning each resource to one writer.
        for offset in 0..<(chunks.map(\.count).max() ?? 0) {
            for chunk in chunks where offset < chunk.count {
                let segment = chunk[offset]
                for resource in [segment.key, segment.map, segment.resource].compactMap({ $0 }) {
                    if seen.insert(resource).inserted { resources.append(resource) }
                }
            }
        }
        let keys = Set(segments.compactMap(\.key))
        let keyGeneration = UUID().uuidString
        let keyNames = Dictionary(uniqueKeysWithValues: keys.map { resource in
            let identity = resource.url.absoluteString + "|" + String(describing: resource.range)
            return (resource, HLSResourceIdentity.filename(identity) + "." + keyGeneration + ".key")
        })
        keyFiles = Set(keyNames.values.map { directory.appendingPathComponent($0) })
        var files: [HLSResource: String] = [:]
        var bytes: Int64 = 0
        var completed = 0
        var transferred: Int64 = 0
        let started = Date()
        try await Task.detached { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }.value
        for offset in stride(from: 0, to: resources.count, by: 4) {
            try await checkpoint()
            let batch = Array(resources[offset..<min(offset + 4, resources.count)])
            try await withThrowingTaskGroup(of: (HLSResource, String, Int64, Int64).self) { group in
                for resource in batch {
                    group.addTask { @MainActor in
                        try await self.checkpoint()
                        let identity = resource.url.absoluteString + "|" + String(describing: resource.range)
                        let name = keyNames[resource] ?? HLSResourceIdentity.filename(identity)
                        let file = directory.appendingPathComponent(name)
                        let existingSize = await Task.detached {
                            (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        }.value
                        if existingSize > 0, !keys.contains(resource) {
                            return (resource, name, Int64(existingSize), 0)
                        }
                        var data: Data?
                        for attempt in 0..<3 {
                            do {
                                data = try await self.session.resource(resource, pageURL: self.pageURL,
                                    userAgent: self.userAgent, provider: self.provider, headers: self.headers).0
                                break
                            } catch {
                                try await self.checkpoint()
                                let failure = error as NSError
                                if attempt == 2 || failure.domain == "AstraMediaHTTP" && [401, 403, 404].contains(failure.code) { throw error }
                                try await Task.sleep(for: .seconds(attempt + 1))
                            }
                        }
                        guard let data, !keys.contains(resource) || data.count == 16 else { throw HLSManifest.Failure.malformed }
                        try await Task.detached { try data.write(to: file, options: .atomic) }.value
                        return (resource, name, Int64(data.count), Int64(data.count))
                    }
                }
                for try await (resource, name, size, downloaded) in group {
                    files[resource] = name
                    completed += 1
                    bytes += size
                    transferred += downloaded
                    let speed = Int64(Double(transferred) / max(0.1, Date().timeIntervalSince(started)))
                    progress(bytes, completed * 95 / resources.count, speed)
                }
            }
        }
        try await checkpoint()
        let text = try plan.localPlaylist(segments: segments, files: files)
        let playlist = directory.appendingPathComponent("local.m3u8")
        try await Task.detached { try text.write(to: playlist, atomically: true, encoding: .utf8) }.value
        return playlist
    }
}

private enum HLSResourceIdentity {
    static func filename(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".bin"
    }
}
