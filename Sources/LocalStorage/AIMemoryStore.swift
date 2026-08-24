// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SQLite3

enum AIMemorySource: String, Codable, Equatable, Sendable {
    case manual
    case conversation
    case summary
}

struct AIMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let source: AIMemorySource
    let createdAt: Date
    let updatedAt: Date
}

struct AIMemoryMatch: Equatable, Sendable {
    let record: AIMemoryRecord
    let similarity: Float
}

enum AIMemoryStoreError: LocalizedError {
    case emptyText
    case textTooLong
    case database(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Memory text cannot be empty."
        case .textTooLong:
            return "A memory can contain at most 4,000 characters."
        case .database(let message):
            return "The local memory database could not be updated: \(message)"
        }
    }
}

/// Account-scoped local AI memory backed by SQLite.
///
/// Each record stores both its source text and a deterministic on-device
/// feature vector. Search computes cosine similarity locally; no memory is
/// sent to an embedding service or shared between accounts.
actor AIMemoryStore {
    static let shared = AIMemoryStore()
    static let maximumTextLength = 4_000
    static let maximumSearchResults = 5
    static let maximumConversationRecords = 2_000

    private static let databaseDirectoryName = "ai-memory"
    private static let databaseFilename = "LocalMemory.sqlite"
    private static let vaultDirectoryName = "Vault"
    private static let vectorDimensions = 384
    private static let vectorModel = "astra-feature-hash-v1"
    private static let minimumSimilarity: Float = 0.10
    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private let fileManager: FileManager
    private var activeCompactionPaths: Set<String> = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func list(storageDirectory: URL) throws -> [AIMemoryRecord] {
        try withDatabase(storageDirectory: storageDirectory) { database in
            let sql = """
                SELECT id, text, source, created_at, updated_at
                FROM memory_entries
                ORDER BY updated_at DESC
                """
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var records: [AIMemoryRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let record = Self.record(from: statement) else { continue }
                records.append(record)
            }
            return records
        }
    }

    @discardableResult
    func add(
        _ rawText: String,
        source: AIMemorySource = .manual,
        now: Date = Date(),
        storageDirectory: URL
    ) throws -> AIMemoryRecord {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIMemoryStoreError.emptyText }
        guard text.count <= Self.maximumTextLength else {
            throw AIMemoryStoreError.textTooLong
        }

        let record = AIMemoryRecord(
            id: UUID(),
            text: text,
            source: source,
            createdAt: now,
            updatedAt: now
        )
        let vectorData = Self.vectorData(for: text)
        try writeMarkdown(record, storageDirectory: storageDirectory)

        return try withDatabase(storageDirectory: storageDirectory) { database in
            let sql = """
                INSERT INTO memory_entries
                    (id, text, source, embedding, embedding_model, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            Self.bind(record.id.uuidString, at: 1, to: statement)
            Self.bind(record.text, at: 2, to: statement)
            Self.bind(record.source.rawValue, at: 3, to: statement)
            _ = vectorData.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    4,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    Self.sqliteTransient
                )
            }
            Self.bind(Self.vectorModel, at: 5, to: statement)
            sqlite3_bind_double(statement, 6, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, record.updatedAt.timeIntervalSince1970)
            try stepDone(statement, in: database)
            return record
        }
    }

    @discardableResult
    func addConversation(
        userMessage: String,
        assistantMessage: String,
        storageDirectory: URL
    ) throws -> AIMemoryRecord {
        let user = String(userMessage.prefix(1_200))
        let assistant = String(assistantMessage.prefix(2_650))
        return try add(
            "Conversation\nUser: \(user)\nAssistant: \(assistant)",
            source: .conversation,
            storageDirectory: storageDirectory
        )
    }

    @discardableResult
    func delete(id: UUID, storageDirectory: URL) throws -> Bool {
        try withDatabase(storageDirectory: storageDirectory) { database in
            let record = try record(id: id, in: database)
            let statement = try prepare(
                "DELETE FROM memory_entries WHERE id = ?",
                in: database
            )
            defer { sqlite3_finalize(statement) }
            Self.bind(id.uuidString, at: 1, to: statement)
            try stepDone(statement, in: database)
            let deleted = sqlite3_changes(database) > 0
            if deleted, let record {
                try? fileManager.removeItem(
                    at: markdownURL(for: record, storageDirectory: storageDirectory)
                )
            }
            return deleted
        }
    }

    func deleteAll(storageDirectory: URL) throws {
        try withDatabase(storageDirectory: storageDirectory) { database in
            try execute("DELETE FROM memory_entries", in: database)
            for directory in ["Notes", "Conversations", "Summaries"] {
                let url = Self.vaultURL(storageDirectory: storageDirectory)
                    .appendingPathComponent(directory, isDirectory: true)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        }
    }

    func conversationCompactionBatch(
        storageDirectory: URL,
        expiredBefore: Date,
        limit: Int = 20
    ) throws -> [AIMemoryRecord] {
        guard limit > 0 else { return [] }
        return try withDatabase(storageDirectory: storageDirectory) { database in
            let statement = try prepare(
                """
                SELECT id, text, source, created_at, updated_at
                FROM memory_entries
                WHERE source = 'conversation'
                  AND (
                    updated_at < ?
                    OR id NOT IN (
                      SELECT id FROM memory_entries
                      WHERE source = 'conversation'
                      ORDER BY updated_at DESC
                      LIMIT ?
                    )
                  )
                ORDER BY updated_at ASC
                LIMIT ?
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, expiredBefore.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(Self.maximumConversationRecords))
            sqlite3_bind_int(statement, 3, Int32(min(limit, 50)))

            var records: [AIMemoryRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = Self.record(from: statement) {
                    records.append(record)
                }
            }
            return records
        }
    }

    func beginCompaction(storageDirectory: URL) -> Bool {
        let key = Self.databaseURL(storageDirectory: storageDirectory).path
        return activeCompactionPaths.insert(key).inserted
    }

    func endCompaction(storageDirectory: URL) {
        activeCompactionPaths.remove(
            Self.databaseURL(storageDirectory: storageDirectory).path
        )
    }

    func delete(
        ids: [UUID],
        storageDirectory: URL
    ) throws {
        guard !ids.isEmpty else { return }
        try withDatabase(storageDirectory: storageDirectory) { database in
            try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
            do {
                let statement = try prepare(
                    "DELETE FROM memory_entries WHERE id = ? AND source = 'conversation'",
                    in: database
                )
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    Self.bind(id.uuidString, at: 1, to: statement)
                    try stepDone(statement, in: database)
                }
                try execute("COMMIT", in: database)
                for id in ids {
                    let record = AIMemoryRecord(
                        id: id,
                        text: "",
                        source: .conversation,
                        createdAt: .distantPast,
                        updatedAt: .distantPast
                    )
                    try? fileManager.removeItem(
                        at: markdownURL(for: record, storageDirectory: storageDirectory)
                    )
                }
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
    }

    func search(
        query rawQuery: String,
        storageDirectory: URL,
        limit: Int = maximumSearchResults
    ) throws -> [AIMemoryMatch] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let queryVector = Self.vector(for: query)
        guard queryVector.contains(where: { $0 != 0 }) else { return [] }

        return try withDatabase(storageDirectory: storageDirectory) { database in
            let sql = """
                SELECT id, text, source, embedding, created_at, updated_at
                FROM memory_entries
                WHERE embedding_model = ?
                """
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            Self.bind(Self.vectorModel, at: 1, to: statement)

            var matches: [AIMemoryMatch] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let record = Self.record(
                    from: statement,
                    sourceColumn: 2,
                    createdAtColumn: 4,
                    updatedAtColumn: 5
                ), let vector = Self.vector(from: statement, column: 3),
                   vector.count == queryVector.count else {
                    continue
                }
                let similarity = zip(queryVector, vector).reduce(Float.zero) {
                    $0 + $1.0 * $1.1
                }
                guard similarity >= Self.minimumSimilarity else { continue }
                matches.append(AIMemoryMatch(record: record, similarity: similarity))
            }

            return matches
                .sorted {
                    if $0.similarity == $1.similarity {
                        return $0.record.updatedAt > $1.record.updatedAt
                    }
                    return $0.similarity > $1.similarity
                }
                .prefix(min(limit, Self.maximumSearchResults))
                .map { $0 }
        }
    }

    static func databaseURL(storageDirectory: URL) -> URL {
        storageDirectory
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(databaseFilename, isDirectory: false)
    }

    static func vaultURL(storageDirectory: URL) -> URL {
        storageDirectory
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(vaultDirectoryName, isDirectory: true)
    }

    func prepareVault(storageDirectory: URL) throws -> URL {
        let vaultURL = Self.vaultURL(storageDirectory: storageDirectory)
        for directory in [
            "Inbox", "Notes", "Projects", "Daily", "Attachments",
            "Templates", "Conversations", "Summaries",
        ] {
            try fileManager.createDirectory(
                at: vaultURL.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return vaultURL
    }

    private func withDatabase<Result>(
        storageDirectory: URL,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let databaseURL = Self.databaseURL(storageDirectory: storageDirectory)
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try prepareVault(storageDirectory: storageDirectory)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open the database."
            if let database { sqlite3_close(database) }
            throw AIMemoryStoreError.database(message)
        }
        defer { sqlite3_close(database) }

        try execute("PRAGMA journal_mode = WAL", in: database)
        try execute("PRAGMA synchronous = NORMAL", in: database)
        try execute("""
            CREATE TABLE IF NOT EXISTS memory_entries (
                id TEXT PRIMARY KEY NOT NULL,
                text TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'manual',
                embedding BLOB NOT NULL,
                embedding_model TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """, in: database)
        try execute(
            "CREATE INDEX IF NOT EXISTS memory_entries_updated_at ON memory_entries(updated_at DESC)",
            in: database
        )
        try ensureSourceColumn(in: database)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
        return try body(database)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw AIMemoryStoreError.database(message)
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AIMemoryStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AIMemoryStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func record(id: UUID, in database: OpaquePointer) throws -> AIMemoryRecord? {
        let statement = try prepare(
            "SELECT id, text, source, created_at, updated_at FROM memory_entries WHERE id = ?",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        Self.bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.record(from: statement)
    }

    private func writeMarkdown(
        _ record: AIMemoryRecord,
        storageDirectory: URL
    ) throws {
        _ = try prepareVault(storageDirectory: storageDirectory)
        let url = markdownURL(for: record, storageDirectory: storageDirectory)
        try Data(record.text.utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func markdownURL(
        for record: AIMemoryRecord,
        storageDirectory: URL
    ) -> URL {
        let directory: String
        switch record.source {
        case .manual:
            directory = "Notes"
        case .conversation:
            directory = "Conversations"
        case .summary:
            directory = "Summaries"
        }
        return Self.vaultURL(storageDirectory: storageDirectory)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(record.id.uuidString).md", isDirectory: false)
    }

    private func ensureSourceColumn(in database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA table_info(memory_entries)", in: database)
        defer { sqlite3_finalize(statement) }
        var hasSource = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == "source" {
                hasSource = true
                break
            }
        }
        if !hasSource {
            try execute(
                "ALTER TABLE memory_entries ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'",
                in: database
            )
        }
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static func record(
        from statement: OpaquePointer,
        sourceColumn: Int32 = 2,
        createdAtColumn: Int32 = 3,
        updatedAtColumn: Int32 = 4
    ) -> AIMemoryRecord? {
        guard let idText = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idText)),
              let textValue = sqlite3_column_text(statement, 1) else {
            return nil
        }
        return AIMemoryRecord(
            id: id,
            text: String(cString: textValue),
            source: sqlite3_column_text(statement, sourceColumn)
                .flatMap { AIMemorySource(rawValue: String(cString: $0)) }
                ?? .manual,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, createdAtColumn)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, updatedAtColumn))
        )
    }

    private static func vector(from statement: OpaquePointer, column: Int32) -> [Float]? {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0,
              byteCount.isMultiple(of: MemoryLayout<UInt32>.size),
              let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let data = Data(bytes: bytes, count: byteCount)
        return stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)]
                .enumerated()
                .reduce(UInt32.zero) { partial, element in
                    partial | UInt32(element.element) << UInt32(element.offset * 8)
                }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }

    private static func vectorData(for text: String) -> Data {
        var data = Data(capacity: vectorDimensions * MemoryLayout<UInt32>.size)
        for value in vector(for: text) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A deterministic multilingual feature-hash embedding. Word tokens help
    /// Latin-script queries while character n-grams retain useful overlap for
    /// CJK text and mixed-language memories without downloading a model.
    static func vector(for text: String) -> [Float] {
        let normalized = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let words = normalized.split { character in
            !character.isLetter && !character.isNumber
        }
        var features: [(String, Float)] = words.map { ("word:\($0)", 2.0) }

        let characters = normalized.filter { $0.isLetter || $0.isNumber }
        for length in 1...3 where characters.count >= length {
            var start = characters.startIndex
            while let end = characters.index(
                start,
                offsetBy: length,
                limitedBy: characters.endIndex
            ), end <= characters.endIndex {
                let weight: Float = length == 1 ? 0.45 : (length == 2 ? 1.0 : 1.25)
                features.append(("char\(length):\(characters[start..<end])", weight))
                guard start < characters.endIndex else { break }
                start = characters.index(after: start)
            }
        }

        var result = [Float](repeating: 0, count: vectorDimensions)
        for (feature, weight) in features {
            let hash = stableHash(feature)
            let index = Int(hash % UInt64(vectorDimensions))
            let sign: Float = (hash & (1 << 63)) == 0 ? 1 : -1
            result[index] += sign * weight
        }
        let magnitude = sqrt(result.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude > 0 else { return result }
        return result.map { $0 / magnitude }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
