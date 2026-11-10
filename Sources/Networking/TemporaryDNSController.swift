import AppKit
import Foundation
import Security
import SystemConfiguration
import Network

/// Pure merge rules shared by the session and its recovery tests.
enum TemporaryDNSPolicy {
    static let enabledKey = "browserTemporaryNetworkDNSEnabled"
    static let port = 15353

    static func restoredSystemDNS(current: [String: Any], original: [String: Any]?) -> [String: Any]? {
        guard current["ServerAddresses"] as? [String] == ["127.0.0.1"],
              current["ServerPort"] as? Int == port else { return current }
        var restored = current
        for key in ["ServerAddresses", "ServerPort"] {
            restored[key] = original?[key]
        }
        return restored.isEmpty ? nil : restored
    }

}

private struct TemporaryDNSJournal: Codable {
    let serviceID: String
    let originalSystemDNS: Data?
}

private enum TemporaryDNSError: Error {
    case unavailable, authorization, probeFailed
}

/// All methods are invoked serially by the blocking lifecycle adapter.
private actor TemporaryDNSController {
    static let shared = TemporaryDNSController()
    private var relay: AstraDNSRelay?
    private var monitor: Task<Void, Never>?
    private var restorationTask: Task<Void, Error>?
    private var active = false
    private var authorization: AuthorizationRef?
    private var lockFD: Int32 = -1
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.phibrowser.Mac/TemporaryDNS", isDirectory: true)
    private var journalURL: URL { directory.appendingPathComponent("session.plist") }
    private func save(_ journal: TemporaryDNSJournal) throws {
        try PropertyListEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func acquireLock() throws {
        if lockFD >= 0 { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw TemporaryDNSError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw TemporaryDNSError.unavailable }
        lockFD = fd
    }

    private func releaseLock() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    private func preferences() throws -> SCPreferences {
        if authorization == nil {
            guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess else {
                throw TemporaryDNSError.authorization
            }
        }
        guard let authorization,
              let preferences = SCPreferencesCreateWithAuthorization(nil, "Astra temporary DNS" as CFString, nil, authorization) else {
            throw TemporaryDNSError.authorization
        }
        return preferences
    }

    private func systemDNS(serviceID: String, preferences: SCPreferences) throws -> SCNetworkProtocol {
        guard let service = SCNetworkServiceCopy(preferences, serviceID as CFString),
              let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            throw TemporaryDNSError.unavailable
        }
        return dns
    }

    private func applySystemDNS() throws {
        guard let store = SCDynamicStoreCreate(nil, "Astra DNS" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let serviceID = state["PrimaryService"] as? String else { throw TemporaryDNSError.unavailable }
        let preferences = try preferences()
        guard SCPreferencesLock(preferences, true) else { throw TemporaryDNSError.authorization }
        defer { SCPreferencesUnlock(preferences) }
        let dns = try systemDNS(serviceID: serviceID, preferences: preferences)
        let original = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
        let originalData = try original.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        try save(TemporaryDNSJournal(serviceID: serviceID, originalSystemDNS: originalData))
        var applied = original ?? [:]
        applied["ServerAddresses"] = ["127.0.0.1"]
        applied["ServerPort"] = TemporaryDNSPolicy.port
        guard SCNetworkProtocolSetConfiguration(dns, applied as CFDictionary),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw TemporaryDNSError.authorization
        }
    }

    private func restoreSystemDNS(_ journal: TemporaryDNSJournal) throws {
        let serviceID = journal.serviceID
        let preferences = try preferences()
        guard SCPreferencesLock(preferences, true) else { throw TemporaryDNSError.authorization }
        defer { SCPreferencesUnlock(preferences) }
        let dns = try systemDNS(serviceID: serviceID, preferences: preferences)
        let current = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] ?? [:]
        let original = try journal.originalSystemDNS.map {
            try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] ?? [:]
        }
        let restored = TemporaryDNSPolicy.restoredSystemDNS(current: current, original: original)
        guard !NSDictionary(dictionary: current).isEqual(to: restored ?? [:]) else { return }
        guard SCNetworkProtocolSetConfiguration(dns, restored.map { $0 as CFDictionary }),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw TemporaryDNSError.authorization
        }
    }

    func start() async throws {
        try acquireLock()
        if FileManager.default.fileExists(atPath: journalURL.path) { try await restore(release: false) }
        guard UserDefaults.standard.bool(forKey: TemporaryDNSPolicy.enabledKey) else { releaseLock(); return }
        do {
            let resolver = AstraDNSRelay(proxyEndpoint: BrowserProxyPolicy.effectiveLocalEndpoint())
            relay = resolver
            try await resolver.start()
            guard await APIClient.verifyTemporaryDNS(port: TemporaryDNSPolicy.port) else { throw TemporaryDNSError.probeFailed }
            try applySystemDNS()
            active = true
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    await self.checkResolverHealth()
                }
            }
        } catch {
            try await restore(release: true)
            throw error
        }
    }

    private func checkResolverHealth() async {
        guard active else { return }
        let healthy = await APIClient.verifyTemporaryDNS(port: TemporaryDNSPolicy.port)
        guard active, !healthy else { return }
        do { try await restore() }
        catch { AppLogError("[DNS] Resolver recovery is pending") }
    }

    func restore(release: Bool = true) async throws {
        if let restorationTask { try await restorationTask.value; return }
        active = false
        monitor?.cancel()
        monitor = nil
        let task = Task { try await self.performRestore(release: release) }
        restorationTask = task
        defer { restorationTask = nil }
        try await task.value
    }

    private func performRestore(release: Bool) async throws {
        guard lockFD >= 0 else { return }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            await relay?.stop()
            relay = nil
            if release { releaseLock() }
            return
        }
        let journal = try PropertyListDecoder().decode(TemporaryDNSJournal.self, from: Data(contentsOf: journalURL))
        // Restore system DNS before stopping the local resolver.
        try restoreSystemDNS(journal)
        await relay?.stop()
        relay = nil
        try FileManager.default.removeItem(at: journalURL)
        if release { releaseLock() }
    }
}

@objc final class TemporaryDNSLifecycle: NSObject {
    private final class Outcome: @unchecked Sendable { var failed = false }
    static private(set) var lastOperationFailed = false
    @objc static func runResolverProbeIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--astra-dns-relay-smoke") else { return false }
        run {
            let relay = AstraDNSRelay(proxyEndpoint: BrowserProxyPolicy.effectiveLocalEndpoint())
            do {
                try await relay.start()
                let udp = await APIClient.verifyTemporaryDNS(port: TemporaryDNSPolicy.port)
                let tcp = await APIClient.verifyTemporaryDNS(port: TemporaryDNSPolicy.port, tcp: true)
                FileHandle.standardOutput.write(Data("[dns-smoke] UDP=\(udp) TCP=\(tcp)\n".utf8))
                await relay.stop()
            } catch { await relay.stop(); throw error }
        }
        return true
    }

    @objc static func prepareBeforeBrowserStartup() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !CommandLine.arguments.contains("--cef-smoke-test") else { return }
        run { try await TemporaryDNSController.shared.start() }
    }

    @objc @discardableResult static func restoreBeforeExit() -> Bool {
        run { try await TemporaryDNSController.shared.restore() }
    }

    @discardableResult private static func run(_ operation: @escaping @Sendable () async throws -> Void) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        Task.detached {
            defer { finished.signal() }
            do { try await operation() }
            catch { outcome.failed = true; AppLogError("[DNS] Temporary DNS operation failed; recovery journal retained when needed") }
        }
        finished.wait()
        lastOperationFailed = outcome.failed
        return !outcome.failed
    }
}

extension APIClient {
    static func encryptedDNSSession(proxyEndpoint: String?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let proxyEndpoint {
            let parts = proxyEndpoint.split(separator: ":")
            if parts.count == 2, let value = UInt16(parts[1]), let port = NWEndpoint.Port(rawValue: value) {
                var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port))
                proxy.allowFailover = false
                configuration.proxyConfigurations = [proxy]
            }
        }
        return URLSession(configuration: configuration)
    }

    static func encryptedDNSResponse(query: Data, session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://1.1.1.1/dns-query")!)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "application/dns-message", data.count >= 12, data.count <= 65535,
              data.prefix(2) == query.prefix(2) else { throw TemporaryDNSError.probeFailed }
        return data
    }

    static func verifyTemporaryDNS(port: Int, tcp: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
            process.arguments = ["@127.0.0.1", "-p", String(port), "example.com", "A", "+short", "+time=4", "+tries=1"] + (tcp ? ["+tcp"] : [])
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { task in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: task.terminationStatus == 0 && output.split(separator: "\n").contains { APIClient.isPublicIPv4(String($0)) })
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

/// Loopback-only DNS transport. Each connection handles one bounded DNS message.
private actor AstraDNSRelay {
    private let queue = DispatchQueue(label: "com.phibrowser.temporary-dns")
    private let session: URLSession
    private var listeners: [NWListener] = []
    private var starting: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(proxyEndpoint: String?) {
        session = APIClient.encryptedDNSSession(proxyEndpoint: proxyEndpoint)
    }

    func start() async throws {
        do {
            for tcp in [false, true] {
                let parameters = tcp ? NWParameters.tcp : NWParameters.udp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(TemporaryDNSPolicy.port))!)
                let listener = try NWListener(using: parameters)
                listeners.append(listener)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.serve(connection, tcp: tcp) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { await self?.listenerChanged(listener, state: state) }
                }
                try await withCheckedThrowingContinuation { continuation in
                    starting[ObjectIdentifier(listener)] = continuation
                    listener.start(queue: queue)
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    private func listenerChanged(_ listener: NWListener, state: NWListener.State) {
        let key = ObjectIdentifier(listener)
        switch state {
        case .ready: starting.removeValue(forKey: key)?.resume()
        case .failed(let error): starting.removeValue(forKey: key)?.resume(throwing: error)
        case .cancelled: starting.removeValue(forKey: key)?.resume(throwing: CancellationError())
        default: break
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        session.invalidateAndCancel()
    }

    private func receive(_ connection: NWConnection, count: Int?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            if let count {
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TemporaryDNSError.probeFailed) }
                }
            } else {
                connection.receiveMessage { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TemporaryDNSError.probeFailed) }
                }
            }
        }
    }

    private func serve(_ connection: NWConnection, tcp: Bool) async {
        guard connections.count < 128 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: queue)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            connection.cancel()
        }
        defer {
            timeout.cancel()
            connection.cancel()
            connections[key] = nil
        }
        do {
            let query: Data
            if tcp {
                let prefix = [UInt8](try await receive(connection, count: 2))
                let length = Int(prefix[0]) * 256 + Int(prefix[1])
                guard length >= 12 else { return }
                query = try await receive(connection, count: length)
            } else {
                query = try await receive(connection, count: nil)
            }
            guard (12...65535).contains(query.count), query[2] & 0x80 == 0 else { return }
            var response = try await APIClient.encryptedDNSResponse(query: query, session: session)
            if tcp {
                response = Data([UInt8(response.count >> 8), UInt8(response.count & 255)]) + response
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: response, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } catch {
            // The caller retries or receives failure. Never fall back to plaintext DNS.
        }
    }
}
