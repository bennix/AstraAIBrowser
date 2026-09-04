import SwiftUI
import UniformTypeIdentifiers

struct PromptLibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PromptLibraryView: View {
    @ObservedObject private var store = PromptLibraryStore.shared
    let draft: String
    let onUse: (String) -> Void
    @State private var query = ""
    @State private var category = ""
    @State private var editing = SavedPrompt(title: "", category: "", content: "")
    @State private var errorMessage: String?
    @State private var selectedIDs = Set<UUID>()
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument = PromptLibraryDocument()

    static var title: String { NSLocalizedString("promptLibrary.title", value: "Prompt Library", comment: "AI sidebar - Saved prompt library title and button") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title).font(.headline)
            TextField(NSLocalizedString("promptLibrary.search", value: "Search prompts", comment: "Prompt library - Search title, category and content"), text: $query)
            Picker(NSLocalizedString("promptLibrary.filter", value: "Task", comment: "Prompt library - Task category filter"), selection: $category) {
                Text(NSLocalizedString("promptLibrary.all", value: "All tasks", comment: "Prompt library - Show all categories")).tag("")
                ForEach(Array(Set(store.entries.map(\.category))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
            }
            HStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if store.matching(query: query, category: category.isEmpty ? nil : category).isEmpty {
                            Text(NSLocalizedString("promptLibrary.empty", value: "No matching prompts. Create one here or save selected webpage text.", comment: "Prompt library - Empty or filtered list guidance"))
                                .font(.caption).foregroundStyle(.secondary).padding(6)
                        }
                        ForEach(store.matching(query: query, category: category.isEmpty ? nil : category)) { prompt in
                            HStack {
                                Toggle(prompt.title, isOn: Binding(get: { selectedIDs.contains(prompt.id) }, set: { selected in
                                    if selected { selectedIDs.insert(prompt.id) } else { selectedIDs.remove(prompt.id) }
                                })).labelsHidden().toggleStyle(.checkbox)
                            Button { editing = prompt } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: prompt.title).lineLimit(2)
                                    Text(verbatim: prompt.category).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(editing.id == prompt.id ? Color.accentColor.opacity(0.15) : Color.clear)
                            }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(width: 185)
                Divider()
                VStack {
                    TextField(NSLocalizedString("promptLibrary.name", value: "Name", comment: "Prompt library editor - Prompt title"), text: $editing.title)
                    TextField(NSLocalizedString("promptLibrary.category", value: "Task category (e.g. Writing)", comment: "Prompt library editor - Editable category, such as Writing or Research"), text: $editing.category)
                    TextEditor(text: $editing.content).font(.body).border(Color.secondary.opacity(0.3))
                    if let source = editing.sourceURL { Text(verbatim: source).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }.frame(height: 270)
            if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red).lineLimit(3) }
            HStack {
                Button(NSLocalizedString("promptLibrary.selectAll", value: "Select results", comment: "Prompt library - Select every currently filtered prompt")) {
                    selectedIDs = Set(store.matching(query: query, category: category.isEmpty ? nil : category).map(\.id))
                }
                Button(NSLocalizedString("promptLibrary.deleteSelected", value: "Delete selected", comment: "Prompt library - Delete all checked prompts")) {
                    perform {
                        try store.remove(ids: selectedIDs)
                        if selectedIDs.contains(editing.id) { editing = SavedPrompt(title: "", category: "", content: "") }
                        selectedIDs.removeAll()
                    }
                }.disabled(selectedIDs.isEmpty)
                Spacer()
                Button(NSLocalizedString("promptLibrary.import", value: "Import JSON", comment: "Prompt library - Import and merge prompts from a JSON file")) { isImporting = true }
                Button(NSLocalizedString("promptLibrary.export", value: "Export JSON", comment: "Prompt library - Export checked prompts, or all prompts when none are checked")) {
                    perform { exportDocument = PromptLibraryDocument(data: try store.exportData(ids: selectedIDs)); isExporting = true }
                }.disabled(store.entries.isEmpty)
            }
            HStack {
                Button(NSLocalizedString("promptLibrary.new", value: "New", comment: "Prompt library - Create an empty prompt")) { editing = SavedPrompt(title: "", category: category, content: "") }
                Button(NSLocalizedString("promptLibrary.fromDraft", value: "From draft", comment: "Prompt library - Copy the AI composer draft into the editor")) { editing = SavedPrompt(title: String(draft.prefix(50)), category: category, content: draft) }.disabled(draft.isEmpty)
                Button(NSLocalizedString("promptLibrary.delete", value: "Delete", comment: "Prompt library - Delete selected saved prompt")) {
                    perform {
                        try store.remove(editing.id)
                        selectedIDs.remove(editing.id)
                        editing = SavedPrompt(title: "", category: "", content: "")
                    }
                }.disabled(!store.entries.contains { $0.id == editing.id })
                Spacer()
                Button(NSLocalizedString("promptLibrary.save", value: "Save", comment: "Prompt library - Persist edited prompt")) {
                    perform { try store.save(editing) }
                }.disabled(editing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(NSLocalizedString("promptLibrary.use", value: "Insert", comment: "Prompt library - Insert prompt into AI draft without sending")) { onUse(editing.content) }.disabled(editing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 570)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
                try store.importData(Data(contentsOf: url))
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "Astra-Prompts") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
}
