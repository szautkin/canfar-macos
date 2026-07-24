import Foundation
import Observation
import VerbinalKit

enum WorkflowSource: String, Codable, Sendable { case builtIn = "BuiltIn", local = "Local" }
struct WorkflowInfo: Sendable, Identifiable {
    let id: String
    let source: WorkflowSource
    let document: WorkflowDocument
    let rawText: String
    /// Non-nil when an MCP agent created this working copy (robot badge).
    /// Kept in a sidecar JSON, never in the .workflow.md itself, so the
    /// file stays byte-compatible with the Windows dialect.
    var agentAttribution: AgentAttribution? = nil
}

@Observable @MainActor
final class WorkflowStore {
    static let builtInPrefix = "builtin:"
    static let localPrefix = "local:"
    private let directory: URL
    private let builtins: () -> [(String, String)]
    var changeID = UUID()

    init(directory: URL? = nil, builtins: @escaping () -> [(String, String)] = WorkflowStore.loadTemplates) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Verbinal/Workflows", isDirectory: true)
        self.builtins = builtins
    }
    func listBuiltIn() -> [WorkflowInfo] {
        builtins().map { WorkflowInfo(id: Self.builtInPrefix + $0.0, source: .builtIn, document: WorkflowFormat.parse($0.1), rawText: $0.1) }.sorted { $0.document.title.localizedCaseInsensitiveCompare($1.document.title) == .orderedAscending }
    }
    func listLocal() -> [WorkflowInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let attributions = loadAttributions()
        return urls.filter { $0.lastPathComponent.hasSuffix(WorkflowFormat.fileExtension) }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return WorkflowInfo(id: Self.localPrefix + slug(of: url), source: .local, document: WorkflowFormat.parse(text), rawText: text, agentAttribution: attributions[slug(of: url)])
        }.sorted { $0.document.title.localizedCaseInsensitiveCompare($1.document.title) == .orderedAscending }
    }
    func get(_ id: String) -> WorkflowInfo? {
        if id.hasPrefix(Self.builtInPrefix) { return listBuiltIn().first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
        guard id.hasPrefix(Self.localPrefix), let text = try? String(contentsOf: path(for: id), encoding: .utf8) else { return nil }
        return WorkflowInfo(id: id, source: .local, document: WorkflowFormat.parse(text), rawText: text, agentAttribution: loadAttributions()[String(id.dropFirst(Self.localPrefix.count))])
    }
    @discardableResult func saveNew(name: String, text: String, attribution: AgentAttribution? = nil) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.slugify(name); var candidate = base; var count = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + WorkflowFormat.fileExtension).path) { candidate = "\(base)-\(count)"; count += 1 }
        try text.data(using: .utf8)!.write(to: directory.appendingPathComponent(candidate + WorkflowFormat.fileExtension), options: .atomic)
        if let attribution { var map = loadAttributions(); map[candidate] = attribution; saveAttributions(map) }
        changeID = UUID(); return Self.localPrefix + candidate
    }
    func updateText(_ id: String, text: String) throws { let path = try localPath(id); try text.data(using: .utf8)!.write(to: path, options: .atomic); changeID = UUID() }
    func setStepDone(_ id: String, index: Int, done: Bool) throws { let path = try localPath(id); let text = try String(contentsOf: path, encoding: .utf8); try WorkflowFormat.withStepDone(text, stepIndex: index, done: done).data(using: .utf8)!.write(to: path, options: .atomic); changeID = UUID() }
    func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: try localPath(id))
        var map = loadAttributions()
        if map.removeValue(forKey: String(id.dropFirst(Self.localPrefix.count))) != nil { saveAttributions(map) }
        changeID = UUID()
    }
    @discardableResult func useWorkflow(_ id: String, name: String? = nil, attribution: AgentAttribution? = nil) throws -> String { guard let item = get(id) else { throw WorkflowError.missing(id) }; return try saveNew(name: name ?? item.document.title, text: item.rawText, attribution: attribution) }

    // MARK: - Agent attribution sidecar

    /// Slug → attribution for agent-created working copies. Lives beside
    /// the workflow files (not inside them) so the .workflow.md bytes
    /// stay Windows-compatible. Tiny file; read/written on demand.
    private var attributionsURL: URL { directory.appendingPathComponent(".attributions.json") }
    private func loadAttributions() -> [String: AgentAttribution] {
        guard let data = try? Data(contentsOf: attributionsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentAttribution].self, from: data)) ?? [:]
    }
    private func saveAttributions(_ map: [String: AgentAttribution]) {
        if map.isEmpty { try? FileManager.default.removeItem(at: attributionsURL); return }
        try? JSONEncoder().encode(map).write(to: attributionsURL, options: .atomic)
    }

    static func slugify(_ name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
        let result = String(slug.prefix(60))
        return result.isEmpty ? "workflow" : result
    }
    private func path(for id: String) -> URL { directory.appendingPathComponent(String(id.dropFirst(Self.localPrefix.count)) + WorkflowFormat.fileExtension) }
    private func localPath(_ id: String) throws -> URL { guard id.hasPrefix(Self.localPrefix), FileManager.default.fileExists(atPath: path(for: id).path) else { throw id.hasPrefix(Self.builtInPrefix) ? WorkflowError.notLocal : WorkflowError.missing(id) }; return path(for: id) }
    private func slug(of url: URL) -> String { String(url.lastPathComponent.dropLast(WorkflowFormat.fileExtension.count)) }
    private static func loadTemplates() -> [(String, String)] {
        // Prefer the Workflows/ folder resource; fall back to the bundle root
        // for older builds that flattened the templates.
        let urls = Bundle.main.urls(forResourcesWithExtension: "workflow.md", subdirectory: "Workflows")
            ?? Bundle.main.urls(forResourcesWithExtension: "workflow.md", subdirectory: nil)
            ?? []
        return urls.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map {
                (String(url.lastPathComponent.dropLast(WorkflowFormat.fileExtension.count)), $0)
            }
        }
    }
}
