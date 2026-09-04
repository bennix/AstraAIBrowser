import XCTest
@testable import Phi

final class PromptLibraryTests: XCTestCase {
    @MainActor func testAutomaticArchiveAndBulkRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PromptLibraryStore(fileURL: root.appendingPathComponent("a.json"))
        try store.archiveSentText(" First prompt ")
        try store.archiveSentText("First prompt")
        try store.archiveSentText("Second prompt")
        XCTAssertEqual(store.entries.count, 2)
        let target = PromptLibraryStore(fileURL: root.appendingPathComponent("b.json"))
        let data = try store.exportData(ids: [])
        try target.importData(data)
        try target.importData(data)
        XCTAssertEqual(target.entries.count, 2)
        XCTAssertEqual(Set(target.entries.map(\.content)), Set(store.entries.map(\.content)))
        let selected = Set([store.entries[0].id])
        XCTAssertEqual(try JSONDecoder().decode([SavedPrompt].self, from: store.exportData(ids: selected)).count, 1)
        try store.remove(ids: selected)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertThrowsError(try target.importData(Data("bad JSON".utf8)))
        XCTAssertEqual(target.entries.count, 2)
    }
    @MainActor func testPersistenceSearchAndEditing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
        let store = PromptLibraryStore(fileURL: url)
        var prompt = SavedPrompt(title: "Research", category: "Study", content: "Line one\n  Line two", sourceURL: "https://example.com")
        try store.save(prompt)
        XCTAssertEqual(PromptLibraryStore(fileURL: url).entries, [prompt])
        XCTAssertEqual(store.matching(query: "line TWO", category: "Study").count, 1)
        XCTAssertTrue(store.matching(query: "", category: "Writing").isEmpty)
        prompt.content = "Revised"
        try store.save(prompt)
        XCTAssertEqual(store.entries, [prompt])
        try store.remove(prompt.id)
        XCTAssertTrue(PromptLibraryStore(fileURL: url).entries.isEmpty)
    }

    @MainActor func testCorruptLibraryCannotBeOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("invalid document".utf8)
        try original.write(to: url)
        let store = PromptLibraryStore(fileURL: url)
        XCTAssertThrowsError(try store.save(SavedPrompt(title: "Test", category: "", content: "Test")))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
