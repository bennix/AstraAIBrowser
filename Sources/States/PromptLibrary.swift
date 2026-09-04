import Foundation
import Combine

struct SavedPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var category: String
    var content: String
    var sourceURL: String?
}

/// Local prompt documents, following the vocabulary book persistence model.
@MainActor
final class PromptLibraryStore: ObservableObject {
    static let shared = PromptLibraryStore(fileURL: URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory()).appendingPathComponent("PromptLibrary.json"))
    @Published private(set) var entries: [SavedPrompt] = []
    private let fileURL: URL
    private var loadError: Error?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { entries = try JSONDecoder().decode([SavedPrompt].self, from: Data(contentsOf: fileURL)) }
            catch { loadError = error }
        }
    }

    func save(_ prompt: SavedPrompt) throws {
        guard !prompt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = entries.filter { $0.id != prompt.id }
        updated.insert(prompt, at: 0)
        try persist(updated)
    }

    func remove(_ id: UUID) throws {
        try persist(entries.filter { $0.id != id })
    }

    func remove(ids: Set<UUID>) throws {
        try persist(entries.filter { !ids.contains($0.id) })
    }

    func archiveSentText(_ content: String) throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !entries.contains(where: { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == text }) else { return }
        try save(SavedPrompt(title: String(text.prefix(60)), category: "", content: text))
    }

    func exportData(ids: Set<UUID>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ids.isEmpty ? entries : entries.filter { ids.contains($0.id) })
    }

    func importData(_ data: Data) throws {
        guard data.count <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let imported = try JSONDecoder().decode([SavedPrompt].self, from: data)
        guard imported.count <= 10_000, imported.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var updated = entries
        var contents = Set(entries.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) })
        for var prompt in imported {
            let text = prompt.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contents.insert(text).inserted else { continue }
            // Imported identifiers cannot replace unrelated local documents.
            prompt.id = UUID()
            updated.append(prompt)
        }
        try persist(updated)
    }

    func matching(query: String, category: String?) -> [SavedPrompt] {
        entries.filter { entry in
            (category == nil || entry.category == category) &&
            (query.isEmpty || [entry.title, entry.content, entry.category].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private func persist(_ updated: [SavedPrompt]) throws {
        // Do not overwrite an unreadable library with an empty replacement.
        if let loadError { throw loadError }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
        entries = updated
    }
}
