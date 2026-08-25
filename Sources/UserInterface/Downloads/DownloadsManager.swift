// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CefKit
import Combine
import Darwin

/// Download item state enumeration matching Chromium's DownloadItem::DownloadState
enum DownloadState: Int {
    case inProgress = 0
    case complete = 1
    case cancelled = 2
    case interrupted = 3
    
    var displayName: String {
        switch self {
        case .inProgress: return NSLocalizedString("downloads.list.state.downloading", value: "Downloading", comment: "Download state")
        case .complete: return NSLocalizedString("downloads.list.state.completed", value: "Completed", comment: "Download state")
        case .cancelled: return NSLocalizedString("downloads.list.state.cancelled", value: "Cancelled", comment: "Download state")
        case .interrupted: return NSLocalizedString("downloads.list.state.failed", value: "Failed", comment: "Download state")
        }
    }
}

/// Swift model for download item
class DownloadItem: ObservableObject, Identifiable {
    let id: String  // guid
    
    @Published var fileName: String
    @Published var url: String
    @Published var mimeType: String
    @Published var state: DownloadState
    @Published var totalBytes: Int64
    @Published var receivedBytes: Int64
    @Published var percentComplete: Int
    @Published var currentSpeed: Int64
    @Published var startTime: Date?
    @Published var endTime: Date?
    @Published var canShowInFolder: Bool
    @Published var canOpenDownload: Bool
    @Published var canResume: Bool
    @Published var isPaused: Bool
    @Published var isDone: Bool
    @Published var isDangerous: Bool
    @Published var dangerType: Int
    @Published var isInsecure: Bool
    @Published var insecureDownloadStatus: Int
    @Published var targetFilePath: String

    var isCEFDownload: Bool {
        id.hasPrefix("cef-")
    }

    var isMediaDownload: Bool {
        id.hasPrefix("media-")
    }

    var isAppManagedDownload: Bool {
        isCEFDownload || isMediaDownload
    }

    // MARK: - Safety State (delegates to DownloadSafetyComputation)

    var safetyState: DownloadSafetyState {
        DownloadSafetyComputation.computeSafetyState(
            isDangerous: isDangerous,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus,
            downloadState: state.rawValue
        )
    }

    var safetyWarningText: String? {
        guard let key = DownloadSafetyComputation.warningTextKey(
            safetyState: safetyState,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus
        ) else { return nil }
        return NSLocalizedString(key, comment: "Download safety warning text")
    }

    var shortSafetyWarningText: String? {
        guard let key = DownloadSafetyComputation.shortWarningTextKey(
            safetyState: safetyState,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus
        ) else { return nil }
        return NSLocalizedString(key, comment: "Download safety short status text")
    }

    var sourceHost: String {
        guard let urlObj = URL(string: url) else { return url }
        return urlObj.host ?? url
    }
    
    /// Display name shown in UI, falling back to the URL path when needed.
    var displayFileName: String {
        if !fileName.isEmpty {
            return fileName
        }
        if let urlObj = URL(string: url) {
            let lastComponent = urlObj.lastPathComponent
            if !lastComponent.isEmpty && lastComponent != "/" {
                return lastComponent
            }
        }
        return NSLocalizedString("downloads.item.pendingFilenamePlaceholder", value: "Downloading...", comment: "Placeholder text when download filename is not yet available")
    }
    
    var formattedProgress: String {
        let oneGB = 1_000_000_000.0
        let oneMB = 1_000_000.0

        if totalBytes > 0 {
            let received = Double(receivedBytes)
            let total = Double(totalBytes)

            if total >= oneGB {
                let receivedGB = received / oneGB
                let totalGB = total / oneGB
                return String(format: "%.2f / %.2f GB", receivedGB, totalGB)
            } else {
                let receivedMB = received / oneMB
                let totalMB = total / oneMB
                return String(format: "%.1f / %.1f MB", receivedMB, totalMB)
            }
        } else if receivedBytes > 0 {
            let received = Double(receivedBytes)

            if received >= oneGB {
                let receivedGB = received / oneGB
                return String(format: "%.2f GB", receivedGB)
            } else {
                let receivedMB = received / oneMB
                return String(format: "%.1f MB", receivedMB)
            }
        }

        return ""
    }
    
    var formattedSpeed: String {
        guard currentSpeed > 0 else { return "" }
        let speedKB = Double(currentSpeed) / 1000.0
        if speedKB > 1000 {
            return String(format: "%.1f MB/s", speedKB / 1000.0)
        }
        return String(format: "%.0f KB/s", speedKB)
    }
    
    init(from wrapper: DownloadItemWrapper) {
        self.id = wrapper.guid
        self.fileName = wrapper.fileNameToReportUser
        self.url = wrapper.url
        self.mimeType = wrapper.mimeType
        self.state = DownloadState(rawValue: wrapper.state) ?? .inProgress
        self.totalBytes = wrapper.totalBytes
        self.receivedBytes = wrapper.receivedBytes
        self.percentComplete = wrapper.percentComplete
        self.currentSpeed = wrapper.currentSpeed
        self.startTime = wrapper.startTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.startTime) / 1000.0) : nil
        self.endTime = wrapper.endTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.endTime) / 1000.0) : nil
        self.canShowInFolder = wrapper.canShowInFolder && !wrapper.fileExternallyRemoved
        self.canOpenDownload = wrapper.canOpenDownload
        self.canResume = wrapper.canResume
        self.isPaused = wrapper.isPaused
        self.isDone = wrapper.isDone
        self.isDangerous = wrapper.isDangerous
        self.dangerType = Int(wrapper.dangerType)
        self.isInsecure = wrapper.isInsecure
        self.insecureDownloadStatus = Int(wrapper.insecureDownloadStatus)
        self.targetFilePath = wrapper.targetFilePath
    }

    func update(from wrapper: DownloadItemWrapper) {
        self.fileName = wrapper.fileNameToReportUser
        self.state = DownloadState(rawValue: wrapper.state) ?? .inProgress
        self.totalBytes = wrapper.totalBytes
        self.receivedBytes = wrapper.receivedBytes
        self.percentComplete = wrapper.percentComplete
        self.currentSpeed = wrapper.currentSpeed
        self.endTime = wrapper.endTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.endTime) / 1000.0) : nil
        self.canShowInFolder = wrapper.canShowInFolder
        self.canOpenDownload = wrapper.canOpenDownload
        self.canResume = wrapper.canResume
        self.isPaused = wrapper.isPaused
        self.isDone = wrapper.isDone
        self.isDangerous = wrapper.isDangerous
        self.dangerType = Int(wrapper.dangerType)
        self.isInsecure = wrapper.isInsecure
        self.insecureDownloadStatus = Int(wrapper.insecureDownloadStatus)
        self.targetFilePath = wrapper.targetFilePath
    }

    init(cefDownload: CefDownload, suggestedName: String, destination: URL) {
        self.id = "cef-\(cefDownload.id)"
        self.fileName = suggestedName
        self.url = cefDownload.url?.absoluteString ?? ""
        self.mimeType = ""
        self.state = .inProgress
        self.totalBytes = cefDownload.totalBytes
        self.receivedBytes = cefDownload.receivedBytes
        self.percentComplete = Self.percentComplete(for: cefDownload)
        self.currentSpeed = 0
        self.startTime = Date()
        self.endTime = nil
        self.canShowInFolder = false
        self.canOpenDownload = false
        self.canResume = false
        self.isPaused = false
        self.isDone = false
        self.isDangerous = false
        self.dangerType = 0
        self.isInsecure = false
        self.insecureDownloadStatus = 0
        self.targetFilePath = destination.path
    }

    init(mediaID: UUID, fileName: String, pageURL: URL, mimeType: String) {
        self.id = "media-\(mediaID.uuidString)"
        self.fileName = fileName
        self.url = pageURL.absoluteString
        self.mimeType = mimeType
        self.state = .inProgress
        self.totalBytes = 0
        self.receivedBytes = 0
        self.percentComplete = -1
        self.currentSpeed = 0
        self.startTime = Date()
        self.endTime = nil
        self.canShowInFolder = false
        self.canOpenDownload = false
        self.canResume = false
        self.isPaused = false
        self.isDone = false
        self.isDangerous = false
        self.dangerType = 0
        self.isInsecure = false
        self.insecureDownloadStatus = 0
        self.targetFilePath = ""
    }

    func updateMediaProgress(
        receivedBytes: Int64,
        totalBytes: Int64,
        speed: Int64
    ) {
        self.receivedBytes = max(0, receivedBytes)
        self.totalBytes = max(0, totalBytes)
        self.currentSpeed = max(0, speed)
        if totalBytes > 0 {
            percentComplete = min(99, max(0, Int(receivedBytes * 100 / totalBytes)))
        }
    }

    func finishMediaDownload(at fileURL: URL) {
        fileName = fileURL.lastPathComponent
        targetFilePath = fileURL.path
        state = .complete
        percentComplete = 100
        currentSpeed = 0
        endTime = Date()
        isDone = true
        canShowInFolder = FileManager.default.fileExists(atPath: fileURL.path)
        canOpenDownload = canShowInFolder
        canResume = false
        isPaused = false
    }

    func failMediaDownload(cancelled: Bool) {
        state = cancelled ? .cancelled : .interrupted
        currentSpeed = 0
        endTime = Date()
        isDone = true
        canShowInFolder = false
        canOpenDownload = false
        canResume = false
        isPaused = false
    }

    func update(from download: CefDownload, currentSpeed: Int64) {
        totalBytes = download.totalBytes
        receivedBytes = download.receivedBytes
        percentComplete = Self.percentComplete(for: download)
        self.currentSpeed = currentSpeed
        if let fullPath = download.fullPath {
            targetFilePath = fullPath.path
            if fileName.isEmpty {
                fileName = fullPath.lastPathComponent
            }
        }

        if download.isComplete {
            state = .complete
            percentComplete = 100
            endTime = Date()
            isDone = true
            canShowInFolder = FileManager.default.fileExists(atPath: targetFilePath)
            canOpenDownload = canShowInFolder
        } else if download.isCanceled {
            state = .interrupted
            endTime = Date()
            isDone = true
            canShowInFolder = false
            canOpenDownload = false
        } else {
            state = .inProgress
            isDone = false
        }
    }

    private static func percentComplete(for download: CefDownload) -> Int {
        guard download.totalBytes > 0 else { return -1 }
        return min(100, max(0, Int(download.receivedBytes * 100 / download.totalBytes)))
    }

    #if DEBUG
    /// Mock initializer for preview and testing
    init(id: String, fileName: String, url: String, state: DownloadState = .complete, 
         percentComplete: Int = 100, totalBytes: Int64 = 0, receivedBytes: Int64 = 0) {
        self.id = id
        self.fileName = fileName
        self.url = url
        self.mimeType = ""
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.percentComplete = percentComplete
        self.currentSpeed = 0
        self.startTime = Date()
        self.endTime = state == .complete ? Date() : nil
        self.canShowInFolder = state == .complete
        self.canOpenDownload = state == .complete
        self.canResume = state == .interrupted
        self.isPaused = false
        self.isDone = state == .complete
        self.isDangerous = false
        self.dangerType = 0
        self.isInsecure = false
        self.insecureDownloadStatus = 0
        self.targetFilePath = "/Downloads/\(fileName)"
    }
    #endif
}

extension DownloadItem {
    /// Maximum age for a download to be considered "new" in the floating list.
    static let maxCreationAge: TimeInterval = 5.0
    var isNewlyCreate: Bool {
        return Date().timeIntervalSince(startTime ?? Date.distantPast) <= Self.maxCreationAge
    }
}

/// Download event for publishing to observers
struct DownloadEvent {
    let eventType: DownloadEventType
    let downloadItem: DownloadItem?
}

enum MediaDownloadKind: String {
    case video
    case audio

    var mimeType: String {
        switch self {
        case .video: return "video/mp4"
        case .audio: return "audio/mp4"
        }
    }

    var displayName: String {
        switch self {
        case .video:
            return NSLocalizedString(
                "downloads.media.videoKindLabel",
                value: "Video",
                comment: "Downloads popover - Media type label for a saved video"
            )
        case .audio:
            return NSLocalizedString(
                "downloads.media.audioKindLabel",
                value: "Audio",
                comment: "Downloads popover - Media type label for a saved audio track"
            )
        }
    }
}

enum MediaDownloadQuality: Int, CaseIterable, Identifiable {
    case best = 0
    case p2160 = 2160
    case p1440 = 1440
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
    case p360 = 360

    var id: Int { rawValue }

    var maximumHeight: Int? {
        self == .best ? nil : rawValue
    }

    var displayName: String {
        guard let maximumHeight else {
            return NSLocalizedString(
                "downloads.media.bestAvailableQuality",
                value: "Best Available",
                comment: "Downloads popover - Video quality option that selects the best available format"
            )
        }
        return "\(maximumHeight)p"
    }
}

enum MediaDownloadFormatPolicy {
    static func arguments(
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        ffmpegDirectory: URL?
    ) -> [String] {
        switch kind {
        case .audio:
            return ["--format", "ba[ext=m4a]/ba/b"]
        case .video:
            let selector: String
            if let maximumHeight = quality.maximumHeight {
                if ffmpegDirectory != nil {
                    selector = "bv*[height<=\(maximumHeight)]+ba/b[height<=\(maximumHeight)]"
                } else {
                    selector = "b[ext=mp4][height<=\(maximumHeight)]/b[height<=\(maximumHeight)]"
                }
            } else {
                selector = ffmpegDirectory == nil ? "b[ext=mp4]/b" : "bv*+ba/b"
            }

            var arguments: [String] = []
            if let ffmpegDirectory {
                arguments += ["--ffmpeg-location", ffmpegDirectory.path]
            }
            arguments += ["--format", selector]
            if ffmpegDirectory != nil {
                arguments += ["--merge-output-format", "mp4"]
            }
            return arguments
        }
    }
}

enum MediaDownloadProgressPolicy {
    static func parse(_ line: String) -> (
        receivedBytes: Int64,
        totalBytes: Int64,
        speed: Int64
    )? {
        guard line.hasPrefix("__ASTRA_PROGRESS__:") else { return nil }
        let values = line.dropFirst("__ASTRA_PROGRESS__:".count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard values.count >= 3 else { return nil }
        func number(_ value: Substring) -> Int64 {
            Int64(Double(value.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        return (number(values[0]), number(values[1]), number(values[2]))
    }
}

enum MediaDownloadSourcePolicy {
    static func canonicalPageURL(_ pageURL: URL) -> URL {
        guard let host = pageURL.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return pageURL }
        let components = pageURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2,
              components[0].lowercased() == "shorts",
              !components[1].isEmpty else { return pageURL }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "www.youtube.com"
        canonical.path = "/watch"
        canonical.queryItems = [URLQueryItem(name: "v", value: components[1])]
        return canonical.url ?? pageURL
    }

    static func orderedSourceURLs(
        pageURL: URL,
        selectedCandidate: MediaDownloadCandidate?
    ) -> [URL] {
        let canonicalURL = canonicalPageURL(pageURL)
        let candidates: [URL]
        if canonicalURL != pageURL {
            candidates = [canonicalURL, selectedCandidate?.url, pageURL].compactMap { $0 }
        } else {
            candidates = [selectedCandidate?.url, pageURL].compactMap { $0 }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    static func cookieSourceURLs(pageURL: URL, sourceURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        return ([pageURL] + sourceURLs).filter { seen.insert($0.absoluteString).inserted }
    }
}

enum MediaDownloadPolicy {
    enum Decision: Equatable {
        case allow
        case rejectDRM
        case rejectUnverified
    }

    static func decision(for data: Data) -> Decision {
        guard let object = metadataObject(in: data) else {
            return .rejectUnverified
        }
        if object["has_drm"] as? Bool == true {
            return .rejectDRM
        }
        guard let formats = object["formats"] as? [[String: Any]], !formats.isEmpty else {
            return .rejectUnverified
        }
        let playableFormats = formats.filter { format in
            format["has_drm"] as? Bool != true
        }
        return playableFormats.isEmpty ? .rejectDRM : .allow
    }

    static func metadataIndicatesDRM(_ data: Data) -> Bool {
        decision(for: data) == .rejectDRM
    }

    static func failureSummary(in data: Data) -> String? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let cleaned = line.replacingOccurrences(
                of: "\\u{001B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )
            if let range = cleaned.range(of: "ERROR:", options: .caseInsensitive) {
                let message = cleaned[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? nil : String(message.prefix(240))
            }
        }
        return nil
    }

    private static func metadataObject(in data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let candidate = Data(line.utf8)
            if let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}

private final class MediaToolProcess: @unchecked Sendable {
    struct Result {
        let exitCode: Int32
        let output: Data
    }

    let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var pendingLine = Data()
    private let lineHandler: @Sendable (String) -> Void

    init(executableURL: URL, arguments: [String], lineHandler: @escaping @Sendable (String) -> Void) {
        self.lineHandler = lineHandler
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
    }

    func run() async throws -> Result {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                guard let self else {
                    continuation.resume(returning: Result(exitCode: process.terminationStatus, output: Data()))
                    return
                }
                self.pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = self.pipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty {
                    self.consume(remaining)
                }
                self.flushPendingLine()
                self.lock.lock()
                let output = self.output
                self.lock.unlock()
                continuation.resume(returning: Result(exitCode: process.terminationStatus, output: output))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func pause() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGSTOP)
    }

    func resume() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGCONT)
    }

    private func consume(_ data: Data) {
        lock.lock()
        output.append(data)
        pendingLine.append(data)
        var lines: [String] = []
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine.prefix(upTo: newline)
            pendingLine.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        lock.unlock()
        lines.forEach(lineHandler)
    }

    private func flushPendingLine() {
        lock.lock()
        let lineData = pendingLine
        pendingLine.removeAll(keepingCapacity: false)
        lock.unlock()
        guard !lineData.isEmpty,
              let line = String(data: lineData, encoding: .utf8) else { return }
        lineHandler(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
private final class MediaDownloadCoordinator {
    private weak var manager: DownloadsManager?
    private var processes: [String: MediaToolProcess] = [:]
    private var cancelledIDs = Set<String>()

    init(manager: DownloadsManager) {
        self.manager = manager
    }

    func start(
        item: DownloadItem,
        sourceURLs: [URL],
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        cookies: [HTTPCookie]
    ) {
        Task { [weak self, weak item] in
            guard let self, let item else { return }
            await self.perform(
                item: item,
                sourceURLs: sourceURLs,
                kind: kind,
                quality: quality,
                cookies: cookies
            )
        }
    }

    func cancel(_ item: DownloadItem) {
        cancelledIDs.insert(item.id)
        processes[item.id]?.terminate()
        item.failMediaDownload(cancelled: true)
        finishEvent(for: item, eventType: .cancelled)
    }

    func pause(_ item: DownloadItem) {
        guard let process = processes[item.id] else { return }
        process.pause()
        item.isPaused = true
        item.canResume = true
        finishEvent(for: item, eventType: .paused)
    }

    func resume(_ item: DownloadItem) {
        guard let process = processes[item.id] else { return }
        process.resume()
        item.isPaused = false
        item.canResume = false
        finishEvent(for: item, eventType: .resumed)
    }

    private func perform(
        item: DownloadItem,
        sourceURLs: [URL],
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        cookies: [HTTPCookie]
    ) async {
        guard let toolURL = Self.ytDLPURL() else {
            fail(
                item,
                message: NSLocalizedString(
                    "downloads.media.toolUnavailableError",
                    value: "Media saver is unavailable in this build",
                    comment: "Downloads list - Failure text when the private media helper is missing"
                )
            )
            return
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-media-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            fail(item)
            return
        }
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let cookieURL = workDirectory.appendingPathComponent("session-cookies.txt")
        if !cookies.isEmpty {
            try? Self.writeNetscapeCookies(cookies, to: cookieURL)
        }
        let cookieArguments = FileManager.default.fileExists(atPath: cookieURL.path)
            ? ["--cookies", cookieURL.path]
            : []

        var selectedSourceURL: URL?
        var lastFailure: String?
        var foundDRM = false
        for sourceURL in sourceURLs {
            let metadataArguments = [
                "--no-config", "--no-playlist", "--no-warnings", "--skip-download", "--dump-single-json",
            ] + cookieArguments + [sourceURL.absoluteString]
            do {
                let metadataProcess = MediaToolProcess(
                    executableURL: toolURL,
                    arguments: metadataArguments,
                    lineHandler: { _ in }
                )
                processes[item.id] = metadataProcess
                let metadata = try await metadataProcess.run()
                guard !wasCancelled(item) else { return }
                guard metadata.exitCode == 0 else {
                    lastFailure = MediaDownloadPolicy.failureSummary(in: metadata.output) ?? lastFailure
                    continue
                }
                switch MediaDownloadPolicy.decision(for: metadata.output) {
                case .allow:
                    selectedSourceURL = sourceURL
                case .rejectDRM:
                    foundDRM = true
                case .rejectUnverified:
                    break
                }
                if selectedSourceURL != nil { break }
            } catch {
                guard !wasCancelled(item) else { return }
                lastFailure = error.localizedDescription
            }
        }
        guard let selectedSourceURL else {
            if foundDRM {
                fail(
                    item,
                    message: NSLocalizedString(
                        "downloads.media.drmProtectedError",
                        value: "DRM-protected media cannot be saved",
                        comment: "Downloads list - Failure text when encrypted media is intentionally rejected"
                    )
                )
            } else {
                fail(item, message: lastFailure)
            }
            return
        }

        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let baseName = Self.uniqueBaseName(
            title: item.fileName,
            kind: kind,
            quality: quality,
            directory: downloadsDirectory
        )
        let outputTemplate = downloadsDirectory
            .appendingPathComponent("\(baseName).%(ext)s")
            .path
        var arguments = [
            "--no-config",
            "--no-playlist",
            "--newline",
            "--concurrent-fragments", "4",
            "--progress-template", "download:__ASTRA_PROGRESS__:%(progress.downloaded_bytes)s:%(progress.total_bytes,progress.total_bytes_estimate)s:%(progress.speed)s",
            "--print", "after_move:__ASTRA_FILE__:%(filepath)s",
            "--output", outputTemplate,
        ]
        let ffmpegDirectory = Self.ffmpegURL()?.deletingLastPathComponent()
        arguments += MediaDownloadFormatPolicy.arguments(
            kind: kind,
            quality: quality,
            ffmpegDirectory: ffmpegDirectory
        )
        arguments += cookieArguments
        arguments.append(selectedSourceURL.absoluteString)

        do {
            let downloadProcess = MediaToolProcess(
                executableURL: toolURL,
                arguments: arguments,
                lineHandler: { [weak self, weak item] line in
                    Task { @MainActor in
                        guard let self, let item else { return }
                        if let progress = MediaDownloadProgressPolicy.parse(line) {
                            item.updateMediaProgress(
                                receivedBytes: progress.receivedBytes,
                                totalBytes: progress.totalBytes,
                                speed: progress.speed
                            )
                            self.finishEvent(for: item, eventType: .updated)
                        }
                    }
                }
            )
            processes[item.id] = downloadProcess
            let result = try await downloadProcess.run()
            processes[item.id] = nil
            guard !wasCancelled(item) else { return }
            let finalFileURL = Self.finalFileURL(in: result.output)
            guard result.exitCode == 0 else {
                fail(item, message: MediaDownloadPolicy.failureSummary(in: result.output))
                return
            }
            guard let finalFileURL,
                  FileManager.default.fileExists(atPath: finalFileURL.path) else {
                fail(item)
                return
            }
            item.finishMediaDownload(at: finalFileURL)
            finishEvent(for: item, eventType: .completed)
        } catch {
            processes[item.id] = nil
            guard !wasCancelled(item) else { return }
            fail(item)
        }
    }

    private func wasCancelled(_ item: DownloadItem) -> Bool {
        if cancelledIDs.remove(item.id) != nil {
            processes[item.id] = nil
            return true
        }
        return false
    }

    private func fail(_ item: DownloadItem, message: String? = nil) {
        processes[item.id] = nil
        if let message, !message.isEmpty {
            item.fileName = message
        } else {
            item.fileName = NSLocalizedString(
                "downloads.media.genericFailureError",
                value: "Media could not be saved",
                comment: "Downloads list - Generic media saving failure text"
            )
        }
        item.failMediaDownload(cancelled: false)
        finishEvent(for: item, eventType: .interrupted)
    }

    private func finishEvent(for item: DownloadItem, eventType: DownloadEventType) {
        manager?.mediaDownloadDidChange(item, eventType: eventType)
    }

    private static func ytDLPURL() -> URL? {
        executableURL(
            bundleName: "yt-dlp",
            fallbackPaths: [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
            ]
        )
    }

    private static func ffmpegURL() -> URL? {
        executableURL(
            bundleName: "ffmpeg",
            fallbackPaths: [
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
            ]
        )
    }

    private static func executableURL(bundleName: String, fallbackPaths: [String]) -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("MediaTools", isDirectory: true)
            .appendingPathComponent(bundleName),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return fallbackPaths
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func writeNetscapeCookies(_ cookies: [HTTPCookie], to url: URL) throws {
        var lines = ["# Netscape HTTP Cookie File", "# Temporary Astra browser session export"]
        for cookie in cookies {
            let domain = sanitizedCookieField(cookie.domain)
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let path = sanitizedCookieField(cookie.path.isEmpty ? "/" : cookie.path)
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expires = Int64(cookie.expiresDate?.timeIntervalSince1970 ?? 0)
            let name = sanitizedCookieField(cookie.name)
            let value = sanitizedCookieField(cookie.value)
            lines.append([domain, includeSubdomains, path, secure, String(expires), name, value].joined(separator: "\t"))
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func sanitizedCookieField(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private static func uniqueBaseName(
        title: String,
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        directory: URL
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedTitle = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String((cleanedTitle.isEmpty ? "media" : cleanedTitle).prefix(120))
        let qualitySuffix = kind == .video && quality != .best ? " \(quality.displayName)" : ""
        let base = "\(stem) - \(kind.displayName)\(qualitySuffix)"
        let existingNames = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        )
        var candidate = base
        var suffix = 2
        while existingNames.contains(where: { $0 == candidate || $0.hasPrefix("\(candidate).") }) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func finalFileURL(in output: Data) -> URL? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix("__ASTRA_FILE__:") else { continue }
            let path = line.dropFirst("__ASTRA_FILE__:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

class DownloadsManager: ObservableObject {
    weak var browserState: BrowserState?
    
    @Published var downloads: [DownloadItem] = []
    
    /// Aggregate progress across all in-progress downloads.
    @Published var totalDownloadProgress: Double = 0.0
    
    /// Publisher consumed by living-download UI and other observers.
    let downloadEventPublisher = PassthroughSubject<DownloadEvent, Never>()
    
    /// Number of currently active downloads.
    var activeDownloadCount: Int {
        downloads.filter { $0.state == .inProgress }.count
    }
    
    /// Whether there are any active downloads.
    var hasActiveDownloads: Bool {
        activeDownloadCount > 0
    }
    
    private var windowId: Int64 {
        Int64(browserState?.windowId ?? 0)
    }

    private var cefProgressSamples: [String: (date: Date, receivedBytes: Int64)] = [:]
    private lazy var mediaDownloadCoordinator = MainActor.assumeIsolated {
        MediaDownloadCoordinator(manager: self)
    }
    
    init(browserState: BrowserState? = nil) {
        self.browserState = browserState
    }

    func startMediaDownload(
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality = .best
    ) {
        guard let tab = browserState?.focusingTab,
              let rawURL = tab.url,
              let pageURL = URL(string: rawURL),
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return }

        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let provider = tab.webContentWrapper as? MediaSessionCookieProviding
            let candidates = await provider?.mediaDownloadCandidates(for: pageURL) ?? []
            let selectedCandidate: MediaDownloadCandidate?
            if candidates.count > 1 {
                guard let selection = await self.chooseMediaCandidate(from: candidates) else { return }
                selectedCandidate = selection
            } else {
                selectedCandidate = candidates.first
            }

            let selectedTitle = selectedCandidate?.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let itemTitle: String
            if let selectedTitle, !selectedTitle.isEmpty {
                itemTitle = String(selectedTitle.prefix(120))
            } else {
                itemTitle = title.isEmpty ? (pageURL.host ?? "Media") : title
            }
            let item = DownloadItem(
                mediaID: UUID(),
                fileName: itemTitle,
                pageURL: pageURL,
                mimeType: kind.mimeType
            )
            self.downloads.insert(item, at: 0)
            self.updateTotalProgress()
            self.downloadEventPublisher.send(
                DownloadEvent(eventType: .created, downloadItem: item)
            )

            let sourceURLs = MediaDownloadSourcePolicy.orderedSourceURLs(
                pageURL: pageURL,
                selectedCandidate: selectedCandidate
            )

            var cookies: [HTTPCookie] = []
            let cookieSourceURLs = MediaDownloadSourcePolicy.cookieSourceURLs(
                pageURL: pageURL,
                sourceURLs: sourceURLs
            )
            for cookieSourceURL in cookieSourceURLs {
                let sourceCookies = await provider?.mediaSessionCookies(for: cookieSourceURL) ?? []
                cookies = Self.mergingCookies(cookies, sourceCookies)
            }
            guard item.state == .inProgress else { return }
            self.mediaDownloadCoordinator.start(
                item: item,
                sourceURLs: sourceURLs,
                kind: kind,
                quality: quality,
                cookies: cookies
            )
        }
    }

    private func chooseMediaCandidate(
        from candidates: [MediaDownloadCandidate]
    ) async -> MediaDownloadCandidate? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "downloads.media.selectionDialog.title",
            value: "Choose Media",
            comment: "Media download dialog - Title shown when the current page contains multiple media items"
        )
        alert.informativeText = NSLocalizedString(
            "downloads.media.selectionDialog.message",
            value: "This page contains multiple media items. Choose which one to save.",
            comment: "Media download dialog - Explanation shown before choosing one of several detected media items"
        )

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
        for (index, candidate) in candidates.enumerated() {
            popup.addItem(withTitle: Self.mediaCandidateMenuTitle(candidate, index: index))
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: NSLocalizedString(
            "downloads.media.selectionDialog.confirmButton",
            value: "Download",
            comment: "Media download dialog - Button that confirms the selected media item"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "downloads.media.selectionDialog.cancelButton",
            value: "Cancel",
            comment: "Media download dialog - Button that cancels media selection"
        ))

        let response: NSApplication.ModalResponse
        if let window = browserState?.windowController?.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn,
              candidates.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return candidates[popup.indexOfSelectedItem]
    }

    private static func mediaCandidateMenuTitle(
        _ candidate: MediaDownloadCandidate,
        index: Int
    ) -> String {
        let fallback = String(
            format: NSLocalizedString(
                "downloads.media.selectionDialog.untitledItem",
                value: "Media %d",
                comment: "Media download dialog - Fallback label for an unnamed detected media item; placeholder is its one-based position"
            ),
            index + 1
        )
        let compactTitle = candidate.title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = compactTitle.isEmpty ? fallback : String(compactTitle.prefix(90))
        let kind = candidate.kind == .audio
            ? MediaDownloadKind.audio.displayName
            : MediaDownloadKind.video.displayName
        guard let duration = candidate.durationSeconds,
              duration.isFinite,
              duration > 0 else {
            return "\(index + 1). \(title) — \(kind)"
        }
        let totalSeconds = Int(duration.rounded())
        let durationText = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        return "\(index + 1). \(title) — \(kind) · \(durationText)"
    }

    private static func mergingCookies(
        _ first: [HTTPCookie],
        _ second: [HTTPCookie]
    ) -> [HTTPCookie] {
        var cookies: [String: HTTPCookie] = [:]
        for cookie in first + second {
            let key = "\(cookie.domain.lowercased())\t\(cookie.path)\t\(cookie.name)"
            cookies[key] = cookie
        }
        return Array(cookies.values)
    }

    fileprivate func mediaDownloadDidChange(
        _ item: DownloadItem,
        eventType: DownloadEventType
    ) {
        updateTotalProgress()
        downloadEventPublisher.send(DownloadEvent(eventType: eventType, downloadItem: item))
    }

    /// Registers a CEF download and returns the collision-free file destination.
    func beginCEFDownload(_ download: CefDownload, suggestedName: String) -> URL {
        let destination = uniqueDownloadDestination(suggestedName: suggestedName)
        let id = "cef-\(download.id)"
        if downloads.contains(where: { $0.id == id }) == false {
            let item = DownloadItem(
                cefDownload: download,
                suggestedName: destination.lastPathComponent,
                destination: destination
            )
            downloads.insert(item, at: 0)
            cefProgressSamples[id] = (Date(), download.receivedBytes)
            updateTotalProgress()
            downloadEventPublisher.send(DownloadEvent(eventType: .created, downloadItem: item))
        }
        return destination
    }

    /// Applies a CEF progress snapshot to the existing native download manager.
    func handleCEFDownloadProgress(_ download: CefDownload) {
        let id = "cef-\(download.id)"
        guard let item = downloads.first(where: { $0.id == id }) else { return }

        let now = Date()
        let previous = cefProgressSamples[id]
        let speed: Int64
        if let previous {
            let elapsed = now.timeIntervalSince(previous.date)
            speed = elapsed > 0 ? max(0, Int64(Double(download.receivedBytes - previous.receivedBytes) / elapsed)) : 0
        } else {
            speed = 0
        }
        cefProgressSamples[id] = (now, download.receivedBytes)
        item.update(from: download, currentSpeed: speed)
        updateTotalProgress()

        let eventType: DownloadEventType
        if download.isComplete {
            eventType = .completed
            cefProgressSamples.removeValue(forKey: id)
        } else if download.isCanceled {
            eventType = .interrupted
            cefProgressSamples.removeValue(forKey: id)
        } else {
            eventType = .updated
        }
        downloadEventPublisher.send(DownloadEvent(eventType: eventType, downloadItem: item))
    }

    private func uniqueDownloadDestination(suggestedName: String) -> URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let sanitizedName = (suggestedName as NSString).lastPathComponent
        let safeName = sanitizedName.isEmpty ? "download" : sanitizedName
        var destination = directory.appendingPathComponent(safeName)
        let stem = destination.deletingPathExtension().lastPathComponent
        let pathExtension = destination.pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let candidate = pathExtension.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(pathExtension)"
            destination = directory.appendingPathComponent(candidate)
            suffix += 1
        }
        return destination
    }

    private func updateTotalProgress() {
        let inProgressItems = downloads.filter { $0.state == .inProgress }
        
        guard !inProgressItems.isEmpty else {
            totalDownloadProgress = 0.0
            return
        }
        
        var totalReceived: Int64 = 0
        var totalSize: Int64 = 0
        var unknownSizeCount = 0
        var unknownSizePercentSum = 0
        
        for item in inProgressItems {
            if item.totalBytes > 0 {
                // Known size: use actual bytes
                totalReceived += item.receivedBytes
                totalSize += item.totalBytes
            } else if item.percentComplete >= 0 {
                // Unknown size but has percent: track separately
                unknownSizeCount += 1
                unknownSizePercentSum += item.percentComplete
            }
            // If neither totalBytes nor percentComplete is available, ignore this item
        }
        
        // Calculate progress
        var progress: Double = 0.0
        
        if totalSize > 0 {
            // Weight by byte count for known-size downloads
            let knownSizeProgress = Double(totalReceived) / Double(totalSize)
            
            if unknownSizeCount > 0 {
                // Mix known-size and unknown-size progress
                let unknownSizeProgress = Double(unknownSizePercentSum) / Double(unknownSizeCount * 100)
                let knownWeight = Double(inProgressItems.count - unknownSizeCount) / Double(inProgressItems.count)
                let unknownWeight = Double(unknownSizeCount) / Double(inProgressItems.count)
                progress = knownSizeProgress * knownWeight + unknownSizeProgress * unknownWeight
            } else {
                progress = knownSizeProgress
            }
        } else if unknownSizeCount > 0 {
            // All downloads have unknown size
            progress = Double(unknownSizePercentSum) / Double(unknownSizeCount * 100)
        }
        
        totalDownloadProgress = min(1.0, max(0.0, progress))
    }
    
    /// Refresh download list from Chromium
    func refreshDownloads() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("📥 [Downloads] Bridge not available")
            return
        }
        
        let wrappers = bridge.getAllDownloadItems(withWindowId: windowId)
        
        var newDownloads: [DownloadItem] = []
        for wrapper in wrappers {
            if let existing = downloads.first(where: { $0.id == wrapper.guid }) {
                existing.update(from: wrapper)
                newDownloads.append(existing)
            } else {
                newDownloads.append(DownloadItem(from: wrapper))
            }
        }
        
        // Sort: in-progress first, then by start time (newest first) within each group
        newDownloads.sort { item1, item2 in
            let isInProgress1 = item1.state == .inProgress
            let isInProgress2 = item2.state == .inProgress
            
            // In-progress items come first
            if isInProgress1 != isInProgress2 {
                return isInProgress1
            }
            
            // Within same group, sort by start time (newest first)
            return (item1.startTime ?? .distantPast) > (item2.startTime ?? .distantPast)
        }
        
        let appManagedDownloads = downloads.filter(\.isAppManagedDownload)
        newDownloads.append(contentsOf: appManagedDownloads.filter { managed in
            newDownloads.contains(where: { $0.id == managed.id }) == false
        })
        newDownloads.sort {
            let firstInProgress = $0.state == .inProgress
            let secondInProgress = $1.state == .inProgress
            if firstInProgress != secondInProgress { return firstInProgress }
            return ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast)
        }
        downloads = newDownloads
        updateTotalProgress()
        AppLogDebug("📥 [Downloads] Refreshed \(downloads.count) items, progress: \(Int(totalDownloadProgress * 100))%")
        
        // Check if completed files still exist on disk
        checkCompletedFilesExistence()
    }
    
    /// Asynchronously check if completed download files still exist on disk
    private func checkCompletedFilesExistence() {
        // Get completed items that claim they can show in folder
        let itemsToCheck = downloads.filter { $0.state == .complete && $0.canShowInFolder }
        
        guard !itemsToCheck.isEmpty else { return }
        
        DispatchQueue.global(qos: .utility).async {
            for item in itemsToCheck {
                let filePath = item.targetFilePath
                guard !filePath.isEmpty else { continue }
                
                let fileExists = FileManager.default.fileExists(atPath: filePath)
                
                if !fileExists {
                    // Update property on main thread
                    DispatchQueue.main.async {
                        item.canShowInFolder = false
                        item.canOpenDownload = false
                    }
                }
            }
        }
    }
    
    /// Handle download event from Chromium
    func handleDownloadEvent(eventType: DownloadEventType, guid: String, wrapper: DownloadItemWrapper?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var affectedItem: DownloadItem?
            
            switch eventType {
            case .created:
                if let wrapper = wrapper {
                    let newItem = DownloadItem(from: wrapper)
                    self.downloads.insert(newItem, at: 0)
                    affectedItem = newItem
                }

            case .updated, .completed, .paused, .resumed:
                if let wrapper = wrapper,
                   let existing = self.downloads.first(where: { $0.id == guid }) {
                    existing.update(from: wrapper)
                    affectedItem = existing
                }

            case .cancelled, .interrupted:
                if let wrapper = wrapper,
                   let existing = self.downloads.first(where: { $0.id == guid }) {
                    existing.update(from: wrapper)
                    affectedItem = existing
                }
                
            case .removed, .destroyed:
                affectedItem = self.downloads.first { $0.id == guid }
                self.downloads.removeAll { $0.id == guid }
                
            case .opened:
                // No UI update needed
                break
                
            @unknown default:
                break
            }
            
            // Update total progress after any download event
            self.updateTotalProgress()
            
            // Publish event for observers (LivingDownloadsManager, etc.)
            let event = DownloadEvent(eventType: eventType, downloadItem: affectedItem)
            self.downloadEventPublisher.send(event)
        }
    }
    
    // MARK: - Download Actions
    
    func pauseDownload(_ item: DownloadItem) {
        if item.isMediaDownload {
            MainActor.assumeIsolated {
                mediaDownloadCoordinator.pause(item)
            }
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.pauseDownload(withGuid: item.id, windowId: windowId)
    }
    
    func resumeDownload(_ item: DownloadItem) {
        if item.isMediaDownload {
            MainActor.assumeIsolated {
                mediaDownloadCoordinator.resume(item)
            }
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.resumeDownload(withGuid: item.id, windowId: windowId)
    }
    
    func cancelDownload(_ item: DownloadItem) {
        if item.isMediaDownload {
            MainActor.assumeIsolated {
                mediaDownloadCoordinator.cancel(item)
            }
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.cancelDownload(withGuid: item.id, windowId: windowId)
    }
    
    func removeDownload(_ item: DownloadItem) {
        if item.isAppManagedDownload {
            if item.isMediaDownload, item.state == .inProgress {
                MainActor.assumeIsolated {
                    mediaDownloadCoordinator.cancel(item)
                }
            }
            downloads.removeAll { $0.id == item.id }
            cefProgressSamples.removeValue(forKey: item.id)
            updateTotalProgress()
            downloadEventPublisher.send(DownloadEvent(eventType: .removed, downloadItem: item))
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.removeDownload(withGuid: item.id, windowId: windowId)
    }
    
    func openDownload(_ item: DownloadItem) {
        if item.isAppManagedDownload {
            guard FileManager.default.fileExists(atPath: item.targetFilePath) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: item.targetFilePath))
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.openDownload(withGuid: item.id, windowId: windowId)
    }
    
    func showInFinder(_ item: DownloadItem) {
        if item.isAppManagedDownload {
            guard FileManager.default.fileExists(atPath: item.targetFilePath) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.targetFilePath)])
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.showDownloadInFinder(withGuid: item.id, windowId: windowId)
    }
    
    // MARK: - Safety Actions

    func keepDownload(_ item: DownloadItem) {
        // Only warning state allows Keep; blocked/policyBlocked should only Discard
        guard item.safetyState == .warning else { return }

        if item.isInsecure {
            ChromiumLauncher.sharedInstance().bridge?.validateInsecureDownload(withGuid: item.id, windowId: windowId)
        } else if item.isDangerous {
            ChromiumLauncher.sharedInstance().bridge?.validateDangerousDownload(withGuid: item.id, windowId: windowId)
        }
    }

    func discardDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.removeDownload(withGuid: item.id, windowId: windowId)
    }

    func copyLink(_ item: DownloadItem) {
        let link = item.url
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
    }
}

extension BrowserState {
//    private(set) lazy var downloadsManager: DownloadsManager = { .init(browserState: self) }()
}
