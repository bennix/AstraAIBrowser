// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CefKit
import Combine
import Darwin
import WebKit

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
    @Published var isLiveRecording = false
    @Published var isFinalizingRecording = false
    @Published var mediaStatus: String?
    var recordingDurationSeconds: Double?
    var mediaTimeRange: String?
    var mediaOptionsConfirmed = false
    var mediaPartitionCount = 4
    var mediaRequestHeaders: [String: String] = [:]

    var isCEFDownload: Bool {
        id.hasPrefix("cef-")
    }

    var isMediaDownload: Bool {
        id.hasPrefix("media-")
    }

    var isAppManagedDownload: Bool {
        isCEFDownload || isMediaDownload || id.hasPrefix("webkit-")
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

    init(mediaID: UUID, fileName: String, pageURL: URL, mimeType: String, idPrefix: String = "media") {
        self.id = "\(idPrefix)-\(mediaID.uuidString)"
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
        speed: Int64,
        percent: Int? = nil
    ) {
        self.receivedBytes = max(0, receivedBytes)
        self.totalBytes = max(0, totalBytes)
        self.currentSpeed = max(0, speed)
        if totalBytes > 0 {
            percentComplete = min(99, max(0, Int(receivedBytes * 100 / totalBytes)))
        } else if let percent {
            percentComplete = min(99, max(0, percent))
        }
    }

    func prepareForMediaDownloadAttempt() {
        receivedBytes = 0
        totalBytes = 0
        percentComplete = -1
        currentSpeed = 0
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
                    selector = "bv*[height<=?\(maximumHeight)]+ba/b[height<=?\(maximumHeight)]"
                } else {
                    selector = "b[ext=mp4][height<=?\(maximumHeight)]/b[height<=?\(maximumHeight)]"
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
        speed: Int64,
        percent: Int?
    )? {
        guard line.hasPrefix("__ASTRA_PROGRESS__:") else { return nil }
        let values = line.dropFirst("__ASTRA_PROGRESS__:".count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard values.count >= 3 else { return nil }
        func number(_ value: Substring) -> Int64 {
            Int64(Double(value.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        let percent: Int?
        if values.count >= 4 {
            let value = values[3]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%", with: "")
            percent = Double(value).map { min(99, max(0, Int($0))) }
        } else {
            percent = nil
        }
        return (number(values[0]), number(values[1]), number(values[2]), percent)
    }
}

enum YouTubeDownloadRetryPolicy {
    static func shouldRetryPublicly(url: URL, failure: String?, hasSessionArguments: Bool) -> Bool {
        guard hasSessionArguments, let host = url.host?.lowercased(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" else { return false }
        return failure?.contains("HTTP Error 403") == true
    }
}

enum MediaDownloadAttemptPolicy {
    static func qualities(
        for kind: MediaDownloadKind,
        selectedQuality: MediaDownloadQuality
    ) -> [MediaDownloadQuality] {
        guard kind == .video, selectedQuality != .best else {
            return [selectedQuality]
        }
        return [selectedQuality, .best]
    }
}

enum MediaTimeRangePolicy {
    static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var result = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0,
                  (index == 0 || number < 60) else { return nil }
            result = result * 60 + number
        }
        return result.isFinite ? result : nil
    }

    static func section(start: String, end: String) -> String? {
        guard let first = seconds(start.isEmpty ? "0" : start) else { return nil }
        if end.isEmpty { return "*\(first)-inf" }
        guard let last = seconds(end), last > first else { return nil }
        return "*\(first)-\(last)"
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
        let alternateURLs = selectedCandidate?.alternateURLs ?? []
        let candidates: [URL]
        if canonicalURL != pageURL {
            candidates = [canonicalURL, selectedCandidate?.url]
                .compactMap { $0 } + alternateURLs + [pageURL]
        } else {
            candidates = [selectedCandidate?.url]
                .compactMap { $0 } + alternateURLs + [pageURL]
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    static func cookieSourceURLs(pageURL: URL, sourceURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        return ([pageURL] + sourceURLs).filter { seen.insert($0.absoluteString).inserted }
    }
}

enum SystemMediaPlaybackResolutionPolicy {
    static func arguments(
        pageURL: URL,
        cookieFileURL: URL?
    ) -> [String] {
        var arguments = [
            "--no-config",
            "--no-playlist",
            "--no-warnings",
            "--format", "b[ext=mp4]/b",
            "--get-url",
            "--referer", pageURL.absoluteString,
        ]
        if let cookieFileURL {
            arguments += ["--cookies", cookieFileURL.path]
        }
        arguments.append(pageURL.absoluteString)
        return arguments
    }

    static func resolvedURL(in output: Data) -> URL? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
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

    static func metadataObject(in data: Data) -> [String: Any]? {
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

enum MediaCandidateURLSummary {
    static func text(for url: URL) -> String {
        let host = url.host ?? ""
        let path = (url.path.removingPercentEncoding ?? url.path)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let compactPath = path.count > 68 ? String(path.prefix(24)) + "…" + String(path.suffix(40)) : path
        var parts = [host + compactPath]
        switch url.pathExtension.lowercased() {
        case "m3u8": parts.append("HLS")
        case "mpd": parts.append("DASH")
        case "mp4", "webm", "m4v", "mov", "mp3", "m4a", "aac", "ogg": parts.append(url.pathExtension.uppercased())
        default: break
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hints = items.filter { ["height", "quality", "resolution"].contains($0.name.lowercased()) }.compactMap(\.value)
        let pattern = #"(?:^|[^0-9])([1-9][0-9]{2,3})p(?:$|[^a-zA-Z0-9])"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range(at: 1), in: path) {
            parts.append(String(path[range]) + "p")
        } else if let height = hints.first(where: { value in
            let number = value.hasSuffix("p") ? String(value.dropLast()) : value
            return Int(number).map { (100...8640).contains($0) } ?? false
        }) {
            parts.append(height.hasSuffix("p") ? height : height + "p")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
private final class MediaCandidatePicker: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let candidates: [MediaDownloadCandidate]
    private let titles: [String]
    var onDownload: (() -> Void)?
    var selectedIndex: Int { table.selectedRow }

    init(candidates: [MediaDownloadCandidate], titles: [String]) {
        self.candidates = candidates
        self.titles = titles
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 380))
        table.frame = bounds
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mediaURLs"))
        column.width = 620
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.rowHeight = 120
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.intercellSpacing = NSSize(width: 0, height: 8)
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        addSubview(scroll)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = candidates[row]
        let cell = NSTableCellView()
        let title = NSTextField(wrappingLabelWithString: titles[row])
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let summary = NSTextField(wrappingLabelWithString: MediaCandidateURLSummary.text(for: candidate.url))
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let address = NSTextField(wrappingLabelWithString: candidate.url.absoluteString)
        address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        address.isSelectable = true
        address.lineBreakMode = .byCharWrapping
        address.setAccessibilityLabel(NSLocalizedString("downloads.media.selectionDialog.fullURL", value: "Full media URL", comment: "Media picker - Accessibility label for the selected complete URL"))
        let copy = NSButton(title: NSLocalizedString("downloads.media.selectionDialog.copyURL", value: "Copy URL", comment: "Media picker - Copy the complete selected media URL"), target: self, action: #selector(copyURL(_:)))
        let download = NSButton(title: NSLocalizedString("downloads.media.selectionDialog.confirmButton", value: "Download", comment: "Media download dialog - Button that confirms the selected media item"), target: self, action: #selector(downloadURL(_:)))
        copy.tag = row
        download.tag = row
        let actions = NSStackView(views: [copy, download])
        actions.spacing = 8
        let stack = NSStackView(views: [title, summary, address, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return cell
    }

    @objc private func copyURL(_ button: NSButton) {
        guard candidates.indices.contains(button.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidates[button.tag].url.absoluteString, forType: .string)
    }

    @objc private func downloadURL(_ button: NSButton) {
        guard candidates.indices.contains(button.tag) else { return }
        table.selectRowIndexes(IndexSet(integer: button.tag), byExtendingSelection: false)
        onDownload?()
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
    private let boundsDiagnosticOutput: Bool
    private let lineHandler: @Sendable (String) -> Void

    init(executableURL: URL, arguments: [String], isMediaExtractor: Bool = true, lineHandler: @escaping @Sendable (String) -> Void) {
        self.lineHandler = lineHandler
        boundsDiagnosticOutput = arguments.contains("--progress-template")
        process.executableURL = executableURL
        // yt-dlp does not inherit Chromium's explicit local proxy. Using the same
        // endpoint keeps manifest resolution and media requests on that route.
        let proxyArguments = BrowserProxyPolicy.effectiveLocalEndpoint().map {
            ["--proxy", "http://\($0)"]
        } ?? []
        process.arguments = isMediaExtractor ? ["--socket-timeout", "20"] + proxyArguments + arguments : arguments
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

    func stopRecording() {
        guard process.isRunning else { return }
        process.interrupt()
    }

    func terminate() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGCONT)
        // yt-dlp forwards interruption to ffmpeg and waits for it to exit.
        // Killing only the parent would leave a live recorder running unseen.
        process.interrupt()
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
        // Live recordings can run indefinitely; retain only recent diagnostics.
        if boundsDiagnosticOutput && output.count > 2_097_152 { output.removeFirst(output.count - 2_097_152) }
        pendingLine.append(data)
        var lines: [String] = []
        while let newline = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
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
    private enum DownloadAttemptResult {
        case completed(URL)
        case failed(String?)
        case cancelled
    }

    private weak var manager: DownloadsManager?
    private var processes: [String: MediaToolProcess] = [:]
    private var cancelledIDs = Set<String>()
    private var nativeOperations: [String: HLSDownloadOperation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var retryActions: [String: () -> Void] = [:]
    private var workDirectories: [String: URL] = [:]

    init(manager: DownloadsManager) {
        self.manager = manager
    }

    func start(
        item: DownloadItem,
        sourceURLs: [URL],
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        cookies: [HTTPCookie],
        userAgent: String?,
        provider: MediaSessionCookieProviding?
    ) {
        let originalTitle = item.fileName
        retryActions[item.id] = { [weak self, weak item] in
            guard let self, let item else { return }
            item.fileName = originalTitle
            self.start(item: item, sourceURLs: sourceURLs, kind: kind, quality: quality,
                       cookies: cookies, userAgent: userAgent, provider: provider)
        }
        tasks[item.id] = Task { [weak self, weak item] in
            guard let self, let item else { return }
            defer { self.tasks[item.id] = nil }
            await self.perform(
                item: item,
                sourceURLs: sourceURLs,
                kind: kind,
                quality: quality,
                cookies: cookies,
                userAgent: userAgent,
                provider: provider
            )
        }
    }

    func cancel(_ item: DownloadItem) {
        cancelledIDs.insert(item.id)
        tasks[item.id]?.cancel()
        nativeOperations[item.id]?.cancel()
        retryActions[item.id] = nil
        processes[item.id]?.terminate()
        item.failMediaDownload(cancelled: true)
        finishEvent(for: item, eventType: .cancelled)
    }

    func discard(_ item: DownloadItem) {
        if item.state == .inProgress { cancel(item); return }
        retryActions[item.id] = nil
        cancelledIDs.remove(item.id)
        if let directory = workDirectories.removeValue(forKey: item.id) {
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
    }

    func pause(_ item: DownloadItem) {
        if item.isLiveRecording {
            stopRecording(item)
            return
        }
        if let operation = nativeOperations[item.id], processes[item.id] == nil {
            operation.pause()
            item.isPaused = true
            item.canResume = true
            finishEvent(for: item, eventType: .paused)
            return
        }
        guard let process = processes[item.id] else { return }
        process.pause()
        item.isPaused = true
        item.canResume = true
        finishEvent(for: item, eventType: .paused)
    }

    private func stopRecording(_ item: DownloadItem) {
        guard item.state == .inProgress, item.isLiveRecording,
              !item.isFinalizingRecording, let process = processes[item.id],
              process.process.isRunning else { return }
        item.isFinalizingRecording = true
        item.mediaStatus = NSLocalizedString("downloads.media.finalizing", value: "Saving recording…", comment: "Download progress while live media is finalized")
        process.stopRecording()
        finishEvent(for: item, eventType: .updated)
    }

    func resume(_ item: DownloadItem) {
        if item.state == .interrupted, let retry = retryActions[item.id] {
            item.state = .inProgress
            item.isDone = false
            item.isPaused = false
            item.canResume = false
            item.endTime = nil
            retry()
            return
        }
        if let operation = nativeOperations[item.id], processes[item.id] == nil {
            operation.resume()
            item.isPaused = false
            item.canResume = false
            finishEvent(for: item, eventType: .resumed)
            return
        }
        guard let process = processes[item.id] else { return }
        process.resume()
        item.isPaused = false
        item.canResume = false
        finishEvent(for: item, eventType: .resumed)
    }

    func resolveSystemPlaybackURL(
        for pageURL: URL,
        cookies: [HTTPCookie]
    ) async -> URL? {
        guard let toolURL = Self.ytDLPURL() else { return nil }
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-playback-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let cookieURL = workDirectory.appendingPathComponent("session-cookies.txt")
        let cookieFileURL: URL?
        if cookies.isEmpty {
            cookieFileURL = nil
        } else {
            do {
                try Self.writeNetscapeCookies(cookies, to: cookieURL)
                cookieFileURL = cookieURL
            } catch {
                return nil
            }
        }

        let process = MediaToolProcess(
            executableURL: toolURL,
            arguments: SystemMediaPlaybackResolutionPolicy.arguments(
                pageURL: pageURL,
                cookieFileURL: cookieFileURL
            ),
            lineHandler: { _ in }
        )
        guard let result = try? await process.run(),
              result.exitCode == 0 else { return nil }
        return SystemMediaPlaybackResolutionPolicy.resolvedURL(in: result.output)
    }

    private func perform(
        item: DownloadItem,
        sourceURLs: [URL],
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        cookies: [HTTPCookie],
        userAgent: String?,
        provider: MediaSessionCookieProviding?
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

        let workDirectory = workDirectories[item.id] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-media-\(UUID().uuidString)", isDirectory: true)
        workDirectories[item.id] = workDirectory
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            fail(item)
            return
        }
        defer {
            nativeOperations.removeValue(forKey: item.id)?.close()
            if item.state == .complete || item.state == .cancelled {
                retryActions[item.id] = nil
                workDirectories[item.id] = nil
                Task.detached { try? FileManager.default.removeItem(at: workDirectory) }
            }
        }

        let cookieURL = workDirectory.appendingPathComponent("session-cookies.txt")
        defer { try? FileManager.default.removeItem(at: cookieURL) }
        if !cookies.isEmpty {
            try? Self.writeNetscapeCookies(cookies, to: cookieURL)
        }
        var cookieArguments = FileManager.default.fileExists(atPath: cookieURL.path)
            ? ["--cookies", cookieURL.path]
            : []
        if let userAgent, !userAgent.isEmpty {
            cookieArguments += ["--user-agent", userAgent]
        }

        for name in ["Origin", "Accept", "Accept-Language"] {
            if let value = item.mediaRequestHeaders[name] { cookieArguments += ["--add-headers", "\(name):\(value)"] }
        }
        var lastFailure: String?
        var foundDRM = false
        var foundClearMedia = false
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let baseName = Self.uniqueBaseName(
            title: item.fileName,
            kind: kind,
            quality: quality,
            directory: downloadsDirectory
        )
        let ffmpegDirectory = Self.ffmpegURL()?.deletingLastPathComponent()
        let qualities = MediaDownloadAttemptPolicy.qualities(
            for: kind,
            selectedQuality: quality
        )
        var attemptIndex = 0

        for sourceURL in sourceURLs {
            lastFailure = nil
            let sourceMIME = await provider?.mediaDownloadMIMEType(for: sourceURL) ?? ""
            if sourceURL.pathExtension.lowercased() == "m3u8" || sourceMIME.contains("mpegurl") {
                do {
                    if let temporaryFile = try await downloadNativeHLS(item: item, sourceURL: sourceURL,
                        quality: quality, kind: kind, userAgent: userAgent, provider: provider, workDirectory: workDirectory) {
                        let destination = Self.uniqueMediaDestination(baseName: baseName, sourceFileURL: temporaryFile, directory: downloadsDirectory)
                        try FileManager.default.moveItem(at: temporaryFile, to: destination)
                        item.finishMediaDownload(at: destination)
                        finishEvent(for: item, eventType: .completed)
                        return
                    }
                } catch {
                    guard !wasCancelled(item) else { return }
                    lastFailure = error.localizedDescription
                    fail(item, message: lastFailure)
                    return
                }
            }
            for sessionAttempt in 0...1 {
                if sessionAttempt == 1 && !YouTubeDownloadRetryPolicy.shouldRetryPublicly(
                    url: sourceURL, failure: lastFailure, hasSessionArguments: !cookieArguments.isEmpty
                ) { break }
                let sessionArguments = sessionAttempt == 0 ? cookieArguments : []
                let metadataArguments = [
                    "--no-config", "--no-playlist", "--no-warnings", "--skip-download", "--dump-single-json",
                    "--referer", item.mediaRequestHeaders["Referer"] ?? item.url,
                ] + sessionArguments + [sourceURL.absoluteString]
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
                        foundClearMedia = true
                        let info = MediaDownloadPolicy.metadataObject(in: metadata.output) ?? [:]
                        let isLive = info["is_live"] as? Bool == true || info["live_status"] as? String == "is_live"
                        let formats = info["formats"] as? [[String: Any]] ?? []
                        let isHLS = sourceURL.pathExtension.lowercased() == "m3u8" ||
                            formats.contains { ($0["protocol"] as? String)?.contains("m3u8") == true }
                        if !item.mediaOptionsConfirmed && (isLive || isHLS) {
                            guard await manager?.configureMediaSelection(item, isLive: isLive) == true else {
                                cancel(item)
                                return
                            }
                            guard item.state == .inProgress else { return }
                        }
                        item.isLiveRecording = isLive
                    case .rejectDRM:
                        foundDRM = true
                        continue
                    case .rejectUnverified:
                        continue
                    }
                } catch {
                    guard !wasCancelled(item) else { return }
                    lastFailure = error.localizedDescription
                    continue
                }

                for attemptQuality in qualities {
                    attemptIndex += 1
                    item.prepareForMediaDownloadAttempt()
                    finishEvent(for: item, eventType: .updated)
                    let result = await runDownloadAttempt(
                        item: item,
                        toolURL: toolURL,
                        sourceURL: sourceURL,
                        pageURLString: item.mediaRequestHeaders["Referer"] ?? item.url,
                        kind: kind,
                        quality: attemptQuality,
                        ffmpegDirectory: ffmpegDirectory,
                        cookieArguments: sessionArguments,
                        workDirectory: workDirectory,
                        attemptIndex: attemptIndex
                    )
                    switch result {
                    case .cancelled:
                        return
                    case .failed(let message):
                        lastFailure = message ?? lastFailure
                        // Retrying a live stream would silently record a different time window.
                        if item.isLiveRecording { fail(item, message: lastFailure); return }
                        if sessionAttempt == 0 && YouTubeDownloadRetryPolicy.shouldRetryPublicly(
                            url: sourceURL, failure: lastFailure, hasSessionArguments: !cookieArguments.isEmpty
                        ) { break }
                    case .completed(let temporaryFileURL):
                        do {
                            let destination = Self.uniqueMediaDestination(
                                baseName: baseName,
                                sourceFileURL: temporaryFileURL,
                                directory: downloadsDirectory
                            )
                            try FileManager.default.moveItem(at: temporaryFileURL, to: destination)
                            item.finishMediaDownload(at: destination)
                            finishEvent(for: item, eventType: .completed)
                            return
                        } catch {
                            lastFailure = error.localizedDescription
                        }
                    }
                }
            }
        }

        if foundDRM && !foundClearMedia {
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
    }

    private func downloadNativeHLS(
        item: DownloadItem, sourceURL: URL, quality: MediaDownloadQuality, kind: MediaDownloadKind,
        userAgent: String?, provider: MediaSessionCookieProviding?, workDirectory: URL
    ) async throws -> URL? {
        guard let pageURL = URL(string: item.url), let ffmpeg = Self.ffmpegURL() else { return nil }
        let operation = HLSDownloadOperation(pageURL: pageURL, userAgent: userAgent, provider: provider,
                                             proxy: BrowserProxyPolicy.effectiveLocalEndpoint(), headers: item.mediaRequestHeaders)
        nativeOperations[item.id] = operation
        defer { nativeOperations[item.id] = nil; operation.close() }
        let plan: HLSManifest
        do { plan = try await operation.resolve(sourceURL, maximumHeight: quality.maximumHeight) }
        catch HLSManifest.Failure.unsupported { return nil }
        guard !plan.live, plan.segments.count <= 4000 else { return nil }
        if !item.mediaOptionsConfirmed {
            guard await manager?.configureMediaSelection(item, isLive: false) == true else {
                cancel(item)
                throw CancellationError()
            }
        }
        guard item.state == .inProgress else { throw CancellationError() }
        let range = item.mediaTimeRange?.dropFirst().split(separator: "-").map(String.init) ?? []
        let start = range.first.flatMap(Double.init) ?? 0
        let end = range.count == 2 ? Double(range[1]) : nil
        let segments = plan.selected(start: start, end: end)
        let directory = workDirectory.appendingPathComponent("hls-" + plan.cacheIdentity, isDirectory: true)
        let playlist = try await operation.download(plan, segments: segments, directory: directory,
            partitions: item.mediaPartitionCount) { [weak self, weak item] bytes, percent, speed in
                guard let self, let item, item.state == .inProgress else { return }
                item.updateMediaProgress(receivedBytes: bytes, totalBytes: 0, speed: speed, percent: percent)
                self.finishEvent(for: item, eventType: .updated)
            }
        guard item.state == .inProgress else { throw CancellationError() }
        item.mediaStatus = NSLocalizedString("downloads.media.merging", value: "Merging downloaded segments…", comment: "Media download progress while local segments are merged")
        finishEvent(for: item, eventType: .updated)
        let output = directory.appendingPathComponent(kind == .audio ? "merged.m4a" : "merged.mp4")
        var arguments = ["-nostdin", "-y", "-v", "error", "-protocol_whitelist", "file,crypto,data",
                         "-allowed_extensions", "ALL", "-allowed_segment_extensions", "ALL", "-extension_picky", "0", "-i", playlist.path]
        arguments += kind == .audio ? ["-vn", "-c:a", "aac"] : ["-map", "0:v?", "-map", "0:a?", "-c", "copy"]
        arguments += ["-movflags", "+faststart", output.path]
        let process = MediaToolProcess(executableURL: ffmpeg, arguments: arguments, isMediaExtractor: false, lineHandler: { _ in })
        processes[item.id] = process
        defer { processes[item.id] = nil; item.mediaStatus = nil }
        let result = try await process.run()
        guard item.state == .inProgress else { throw CancellationError() }
        guard result.exitCode == 0, (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw NSError(domain: "AstraHLSMerge", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey:
                NSLocalizedString("downloads.media.mergeFailed", value: "Could not merge media. Downloaded segments are retained for retry.", comment: "Media merge failure with retained fragments")])
        }
        return output
    }

    private func runDownloadAttempt(
        item: DownloadItem,
        toolURL: URL,
        sourceURL: URL,
        pageURLString: String,
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality,
        ffmpegDirectory: URL?,
        cookieArguments: [String],
        workDirectory: URL,
        attemptIndex: Int
    ) async -> DownloadAttemptResult {
        let attemptDirectory = workDirectory
            .appendingPathComponent("attempt-\(attemptIndex)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: attemptDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        let outputTemplate = attemptDirectory
            .appendingPathComponent("media.%(ext)s")
            .path
        var arguments = [
            "--no-config",
            "--no-playlist",
            "--newline",
            // The final-path --print marker implies quiet mode; explicitly enable progress.
            "--progress",
            "--progress-delta", "0.2",
            "--concurrent-fragments", "4",
            "--retries", "5",
            "--fragment-retries", "5",
            "--abort-on-unavailable-fragments",
            "--progress-template", "download:__ASTRA_PROGRESS__:%(progress.downloaded_bytes)s:%(progress.total_bytes,progress.total_bytes_estimate)s:%(progress.speed)s:%(progress._percent_str)s",
            "--print", "after_move:__ASTRA_FILE__:%(filepath)s",
            "--output", outputTemplate,
            "--referer", pageURLString,
        ]
        arguments += MediaDownloadFormatPolicy.arguments(
            kind: kind,
            quality: quality,
            ffmpegDirectory: ffmpegDirectory
        )
        if item.isLiveRecording {
            arguments += ["--downloader", "ffmpeg"]
            if let duration = item.recordingDurationSeconds {
                // Limit captured media time, excluding metadata and connection startup.
                arguments += ["--downloader-args", "ffmpeg_o:-t \(duration)"]
            }
        } else if let range = item.mediaTimeRange {
            arguments += ["--download-sections", range]
        }
        arguments += cookieArguments
        arguments.append(sourceURL.absoluteString)

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
                                speed: progress.speed,
                                percent: progress.percent
                            )
                            self.finishEvent(for: item, eventType: .updated)
                        }
                    }
                }
            )
            processes[item.id] = downloadProcess
            if item.isLiveRecording {
                item.mediaStatus = NSLocalizedString("downloads.media.recording", value: "Recording live stream…", comment: "Download progress while recording live HLS")
                finishEvent(for: item, eventType: .updated)
            }
            let result = try await downloadProcess.run()
            processes[item.id] = nil
            guard !wasCancelled(item) else { return .cancelled }
            let finalFileURL = Self.finalFileURL(in: result.output)
            guard result.exitCode == 0 else {
                return .failed(MediaDownloadPolicy.failureSummary(in: result.output))
            }
            guard let finalFileURL,
                  FileManager.default.fileExists(atPath: finalFileURL.path) else {
                return .failed(nil)
            }
            return .completed(finalFileURL)
        } catch {
            processes[item.id] = nil
            guard !wasCancelled(item) else { return .cancelled }
            return .failed(error.localizedDescription)
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
        item.canResume = retryActions[item.id] != nil
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

    private static func uniqueMediaDestination(
        baseName: String,
        sourceFileURL: URL,
        directory: URL
    ) -> URL {
        let pathExtension = sourceFileURL.pathExtension
        let fileName = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
        var destination = directory.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let suffixedName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            destination = directory.appendingPathComponent(suffixedName)
            suffix += 1
        }
        return destination
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


struct MediaDownloadHistoryRecord: Codable {
    let id: UUID
    let fileName: String
    let pageURL: URL
    let mimeType: String
    let path: String
    let bytes: Int64
    let started: Date?
    let ended: Date?

    init?(_ item: DownloadItem) {
        guard item.isMediaDownload, item.state == .complete,
              let id = UUID(uuidString: String(item.id.dropFirst("media-".count))),
              let pageURL = URL(string: item.url) else { return nil }
        self.id = id
        self.fileName = item.fileName
        self.pageURL = pageURL
        self.mimeType = item.mimeType
        self.path = item.targetFilePath
        self.bytes = item.receivedBytes
        self.started = item.startTime
        self.ended = item.endTime
    }

    func item() -> DownloadItem {
        let item = DownloadItem(mediaID: id, fileName: fileName, pageURL: pageURL, mimeType: mimeType)
        item.updateMediaProgress(receivedBytes: bytes, totalBytes: bytes, speed: 0)
        item.finishMediaDownload(at: URL(fileURLWithPath: path))
        item.startTime = started
        item.endTime = ended
        return item
    }
}

enum MediaDownloadHistory {
    private static let lock = NSLock()

    static func records(profile: String, defaults: UserDefaults = .standard) -> [MediaDownloadHistoryRecord] {
        guard let data = defaults.data(forKey: "downloads.mediaHistory." + profile) else { return [] }
        return (try? JSONDecoder().decode([MediaDownloadHistoryRecord].self, from: data)) ?? []
    }

    static func update(_ item: DownloadItem, profile: String, removing: Bool = false, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        var records = records(profile: profile, defaults: defaults)
        records.removeAll { "media-" + $0.id.uuidString == item.id }
        if !removing, let record = MediaDownloadHistoryRecord(item) { records.append(record) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: "downloads.mediaHistory." + profile)
    }
}

class DownloadsManager: ObservableObject {
    private final class WebKitTransfer: NSObject, WKDownloadDelegate {
        weak var manager: DownloadsManager?
        let download: WKDownload
        let id = UUID()
        var item: DownloadItem?
        var destination: URL?
        var isFinished = false

        init(download: WKDownload, manager: DownloadsManager) {
            self.download = download
            self.manager = manager
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            guard let manager else { completionHandler(nil); return }
            let destination = manager.uniqueDownloadDestination(suggestedName: suggestedFilename)
            self.destination = destination
            let item = DownloadItem(mediaID: id, fileName: destination.lastPathComponent,
                                    pageURL: response.url ?? URL(string: "about:blank")!,
                                    mimeType: response.mimeType ?? "application/octet-stream", idPrefix: "webkit")
            self.item = item
            item.targetFilePath = destination.path
            manager.downloads.insert(item, at: 0)
            manager.updateTotalProgress()
            manager.downloadEventPublisher.send(DownloadEvent(eventType: .created, downloadItem: item))
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let item, let destination {
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                item.updateMediaProgress(receivedBytes: size, totalBytes: size, speed: 0)
                item.finishMediaDownload(at: destination)
                finish(.completed)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let wasCancelled = (error as NSError).code == NSURLErrorCancelled
            item?.failMediaDownload(cancelled: wasCancelled)
            finish(wasCancelled ? .cancelled : .interrupted)
        }

        func finish(_ event: DownloadEventType) {
            guard !isFinished else { return }
            isFinished = true
            if let item {
                manager?.downloadEventPublisher.send(DownloadEvent(eventType: event, downloadItem: item))
            }
            manager?.updateTotalProgress()
            manager?.webKitTransfers.removeValue(forKey: id)
        }
    }

    private var webKitTransfers: [UUID: WebKitTransfer] = [:]

    func beginWebKitDownload(_ download: WKDownload) {
        let transfer = WebKitTransfer(download: download, manager: self)
        webKitTransfers[transfer.id] = transfer
        download.delegate = transfer
    }
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
    @MainActor private var isChoosingMediaCandidate = false
    @MainActor private lazy var mediaDownloadCoordinator = MediaDownloadCoordinator(manager: self)
    
    init(browserState: BrowserState? = nil) {
        self.browserState = browserState
        restoreMediaHistory()
    }

    private func restoreMediaHistory() {
        guard let state = browserState, !state.isIncognito else { return }
        let existing = Set(downloads.map(\.id))
        downloads += MediaDownloadHistory.records(profile: state.profileId)
            .map { $0.item() }.filter { !existing.contains($0.id) }
    }

    func startMediaDownload(
        kind: MediaDownloadKind,
        quality: MediaDownloadQuality = .best,
        sourceURL: URL? = nil,
        originatingPageURL: URL? = nil,
        sessionProvider: MediaSessionCookieProviding? = nil
    ) {
        guard let tab = browserState?.focusingTab,
              let rawURL = tab.url,
              let pageURL = originatingPageURL ?? URL(string: rawURL),
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return }

        let selectedSourceURL = sourceURL.flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = sessionProvider ?? (tab.webContentWrapper as? MediaSessionCookieProviding)
        let item = DownloadItem(mediaID: UUID(), fileName: title.isEmpty ? (pageURL.host ?? "Media") : title,
                                pageURL: pageURL, mimeType: kind.mimeType)
        downloads.insert(item, at: 0)
        updateTotalProgress()
        downloadEventPublisher.send(DownloadEvent(eventType: .created, downloadItem: item))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates: [MediaDownloadCandidate]
            if let sourceURL = selectedSourceURL {
                candidates = [MediaDownloadCandidate(url: sourceURL, title: sourceURL.lastPathComponent,
                    kind: kind == .audio ? .audio : .video, durationSeconds: nil)]
            } else {
                candidates = await provider?.mediaDownloadCandidates(for: pageURL) ?? []
            }
            guard item.state == .inProgress else { return }
            let selectedCandidate: MediaDownloadCandidate?
            if !candidates.isEmpty {
                guard !self.isChoosingMediaCandidate else {
                    item.failMediaDownload(cancelled: true)
                    self.mediaDownloadDidChange(item, eventType: .cancelled)
                    return
                }
                self.isChoosingMediaCandidate = true
                defer { self.isChoosingMediaCandidate = false }
                guard let selection = await self.chooseMediaCandidate(from: candidates) else {
                    item.failMediaDownload(cancelled: true)
                    self.mediaDownloadDidChange(item, eventType: .cancelled)
                    return
                }
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
            item.fileName = itemTitle

            let sourceURLs = selectedSourceURL.map { [$0] } ?? MediaDownloadSourcePolicy.orderedSourceURLs(
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
            item.mediaRequestHeaders = await provider?.mediaDownloadHeaders(for: sourceURLs.first ?? pageURL) ?? [:]
            let fallbackUserAgent = await provider?.mediaDownloadUserAgent()
            let userAgent = item.mediaRequestHeaders["User-Agent"] ?? fallbackUserAgent
            guard item.state == .inProgress else { return }
            self.mediaDownloadCoordinator.start(
                item: item,
                sourceURLs: sourceURLs,
                kind: kind,
                quality: quality,
                cookies: cookies,
                userAgent: userAgent,
                provider: provider
            )
        }
    }

    @MainActor
    func resolveSystemPlaybackURL(
        for pageURL: URL,
        cookies: [HTTPCookie]
    ) async -> URL? {
        await mediaDownloadCoordinator.resolveSystemPlaybackURL(
            for: pageURL,
            cookies: cookies
        )
    }

    @MainActor
    fileprivate func configureMediaSelection(_ item: DownloadItem, isLive: Bool) async -> Bool {
        guard !isChoosingMediaCandidate else { return false }
        isChoosingMediaCandidate = true
        defer { isChoosingMediaCandidate = false }
        let alert = NSAlert()
        alert.messageText = isLive
            ? NSLocalizedString("downloads.media.liveOptions", value: "Record Live Stream", comment: "Live HLS recording options title")
            : NSLocalizedString("downloads.media.hlsOptions", value: "Choose HLS Time Range", comment: "HLS segment selection title")
        let instructions = isLive
            ? NSLocalizedString("downloads.media.liveDuration", value: "Recording duration in minutes. Leave empty to stop manually.", comment: "Live recording duration input instructions")
            : NSLocalizedString("downloads.media.hlsRange", value: "Choose the start and end time in seconds or HH:MM:SS. Leave the end empty to download the rest. The selected segments will be merged into one file.", comment: "HLS time range input instructions")
        alert.informativeText = instructions
        let start = NSTextField(string: isLive ? "" : "0")
        let end = NSTextField(string: "")
        start.placeholderString = isLive
            ? NSLocalizedString("downloads.media.manualDuration", value: "Manual stop", comment: "Empty live recording duration placeholder")
            : NSLocalizedString("downloads.media.startTime", value: "Start time", comment: "HLS start time field")
        end.placeholderString = NSLocalizedString("downloads.media.endTime", value: "End time (optional)", comment: "HLS end time field")
        let partitions = NSPopUpButton()
        partitions.addItems(withTitles: ["1", "2", "4", "8", "16"])
        partitions.selectItem(withTitle: String(item.mediaPartitionCount))
        let partitionLabel = NSTextField(labelWithString: NSLocalizedString("downloads.media.partitions", value: "Time partitions", comment: "HLS selection label for number of temporal download partitions"))
        let partitionRow = NSStackView(views: [partitionLabel, partitions])
        let stack = NSStackView(views: isLive ? [start] : [start, end, partitionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: isLive ? 28 : 100)
        start.widthAnchor.constraint(equalToConstant: 440).isActive = true
        end.widthAnchor.constraint(equalToConstant: 440).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: NSLocalizedString("downloads.media.startSelection", value: "Start", comment: "Confirm media range or live recording duration"))
        alert.addButton(withTitle: NSLocalizedString("downloads.media.selectionDialog.cancelButton", value: "Cancel", comment: "Media download dialog - Button that cancels media selection"))
        while item.state == .inProgress {
            let response: NSApplication.ModalResponse
            if let window = browserState?.windowController?.window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn, item.state == .inProgress else { return false }
            let first = start.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = end.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLive {
                if first.isEmpty {
                    item.recordingDurationSeconds = nil
                } else if let minutes = Double(first), minutes.isFinite, minutes > 0, minutes <= 525600 {
                    item.recordingDurationSeconds = minutes * 60
                } else {
                    alert.informativeText = NSLocalizedString("downloads.media.invalidDuration", value: "Enter a positive duration of up to 525600 minutes, or leave it empty for manual stop.", comment: "Invalid live recording duration error")
                    continue
                }
            } else {
                guard let range = MediaTimeRangePolicy.section(start: first, end: last) else {
                    alert.informativeText = NSLocalizedString("downloads.media.invalidRange", value: "Enter a valid start time and an end time greater than the start, or leave the end empty.", comment: "Invalid HLS time range error")
                    continue
                }
                item.mediaTimeRange = range == "*0.0-inf" ? nil : range
                item.mediaPartitionCount = Int(partitions.titleOfSelectedItem ?? "4") ?? 4
            }
            item.mediaOptionsConfirmed = true
            return true
        }
        return false
    }

    @MainActor
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
            value: "Review the detected media source and choose which one to save.",
            comment: "Media download dialog - Explanation before reviewing a detected media source"
        )

        let titles = candidates.enumerated().map { index, candidate in
            Self.mediaCandidateMenuTitle(candidate, index: index)
        }
        let picker = MediaCandidatePicker(candidates: candidates, titles: titles)
        picker.onDownload = { [weak alert] in
            guard let alert else { return }
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            } else {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        }
        alert.accessoryView = picker
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
              candidates.indices.contains(picker.selectedIndex) else { return nil }
        return candidates[picker.selectedIndex]
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
        if item.state == .complete, let state = browserState, !state.isIncognito {
            MediaDownloadHistory.update(item, profile: state.profileId)
        }
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
        while FileManager.default.fileExists(atPath: destination.path)
            || downloads.contains(where: { $0.state == .inProgress && $0.targetFilePath == destination.path }) {
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
        restoreMediaHistory()
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
        if let transfer = webKitTransfers.values.first(where: { $0.item?.id == item.id }) {
            transfer.download.cancel { _ in }
            item.failMediaDownload(cancelled: true)
            transfer.finish(.cancelled)
            return
        }
        if item.isMediaDownload {
            MainActor.assumeIsolated {
                mediaDownloadCoordinator.cancel(item)
            }
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.cancelDownload(withGuid: item.id, windowId: windowId)
    }
    
    func removeDownload(_ item: DownloadItem) {
        if item.id.hasPrefix("webkit-"), item.state == .inProgress {
            cancelDownload(item)
        }
        if item.isAppManagedDownload {
            if item.isMediaDownload {
                MainActor.assumeIsolated {
                    mediaDownloadCoordinator.discard(item)
                }
            }
            if let state = browserState, !state.isIncognito {
                MediaDownloadHistory.update(item, profile: state.profileId, removing: true)
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
