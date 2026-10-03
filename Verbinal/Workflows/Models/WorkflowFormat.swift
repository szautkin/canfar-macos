import Foundation

struct WorkflowStep: Codable, Sendable, Equatable, Identifiable {
    let index: Int
    let title: String
    let body: String
    let tools: [String]
    /// An add-on's tools for the step, used instead where it is installed (`AddonTools`).
    var addonTools: [String] = []
    let view: String?
    let note: String?
    let done: Bool
    var id: Int { index }

    /// The tools that apply on a Mac with `installed` add-ons: the add-on's
    /// where it is there, else the step's own.
    func toolsHere(installed: Set<String>) -> [String] {
        AddonTools.available(addonTools, installed: installed) ? addonTools : tools
    }
}

struct WorkflowDocument: Codable, Sendable, Equatable {
    let title: String
    let description: String
    let metadata: [String: String]
    let steps: [WorkflowStep]
    let warnings: [String]
    var tags: [String] { metadata.first { $0.key.caseInsensitiveCompare("Tags") == .orderedSame }?.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? [] }
    var doneCount: Int { steps.filter(\.done).count }
}

/// The Windows-compatible `.workflow.md` checklist dialect.  In particular,
/// `withStepDone` does not split/rejoin lines so CRLF bytes survive unchanged.
enum WorkflowFormat {
    static let fileExtension = ".workflow.md"

    static func parse(_ text: String) -> WorkflowDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var title: String?
        var description = ""
        var metadata: [String: String] = [:]
        var warnings: [String] = []
        var steps: [WorkflowStep] = []
        var stepTitle: String?
        var done = false
        var body: [String] = [], tools: [String] = [], addonTools: [String] = []
        var view: String?, note: String?, inStep = false
        func names(_ value: String) -> [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        func flush() {
            guard inStep else { return }
            steps.append(WorkflowStep(index: steps.count, title: stepTitle?.trimmingCharacters(in: .whitespaces) .nilIfEmpty ?? "Step \(steps.count + 1)", body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), tools: tools, addonTools: addonTools, view: view, note: note, done: done))
            stepTitle = nil; done = false; body.removeAll(); tools.removeAll(); addonTools.removeAll(); view = nil; note = nil; inStep = false
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .newlines)
            if let marker = checkbox(in: line) {
                flush(); inStep = true; done = marker.done
                let content = marker.content.trimmingCharacters(in: .whitespaces)
                if content.hasPrefix("**"), let close = content.dropFirst(2).range(of: "**") {
                    stepTitle = String(content[content.index(content.startIndex, offsetBy: 2)..<close.lowerBound])
                    let rest = content[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "—–- "))
                    if !rest.isEmpty { body.append(rest) }
                } else { stepTitle = content }
            } else if inStep {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("#") { flush(); continue }
                if let value = attachment(trimmed, keys: ["Tool", "Tools"]) { tools += names(value) }
                else if let value = attachment(trimmed, keys: ["Add-on", "Addon"]) { addonTools += names(value) }
                else if let value = attachment(trimmed, keys: ["View"]) { view = value.trimmingCharacters(in: .whitespaces) }
                else if let value = attachment(trimmed, keys: ["Note"]) { note = value.trimmingCharacters(in: .whitespaces) }
                else { body.append(trimmed) }
            } else if line.hasPrefix("# "), !line.hasPrefix("##"), title == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("> "), description.isEmpty {
                description = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if !line.hasPrefix("#"), let colon = line.firstIndex(of: ":"), line[..<colon].range(of: #"^[A-Za-z][A-Za-z ]{0,30}$"#, options: .regularExpression) != nil {
                metadata[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        if title == nil { title = "Untitled workflow"; warnings.append("No `# Title` line found — using \"Untitled workflow\".") }
        if steps.isEmpty { warnings.append("No steps found — add lines like `- [ ] **Step title** — description`.") }
        return WorkflowDocument(title: title!, description: description, metadata: metadata, steps: steps, warnings: warnings)
    }

    static func withStepDone(_ text: String, stepIndex: Int, done: Bool) throws -> String {
        var occurrence = 0, index = text.startIndex
        while index < text.endIndex {
            let end = text[index...].firstIndex(where: { $0 == "\r" || $0 == "\n" }) ?? text.endIndex
            let line = String(text[index..<end])
            if line.trimmingCharacters(in: .whitespaces).range(of: #"-\s*\[[ xX]\]"#, options: .regularExpression) != nil {
                if occurrence == stepIndex {
                    guard let open = text[index..<end].firstIndex(of: "[") else { break }
                    let box = text.index(after: open)
                    return String(text[..<box]) + (done ? "x" : " ") + String(text[text.index(after: box)...])
                }
                occurrence += 1
            }
            index = end
            if index < text.endIndex, text[index] == "\r" { index = text.index(after: index) }
            if index < text.endIndex, text[index] == "\n" { index = text.index(after: index) }
        }
        throw WorkflowError.invalidStep(stepIndex, count: occurrence)
    }

    /// `text` with its `# Title` line saying `title` (one added when it has none).
    static func withTitle(_ text: String, _ title: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("# ") && !$0.hasPrefix("##") }) {
            lines[index] = "# \(title)"
            return lines.joined(separator: "\n")
        }
        return "# \(title)\n" + text
    }

    static func skeleton(_ title: String) -> String { "# \(title)\n> One-line description of what this protocol achieves.\nTags: \nTime: ~1 h\n\n## Steps\n\n- [ ] **First step** — What to do and why.\n      Tool: search_observations\n      View: search\n- [ ] **Second step** — ...\n" }

    private static func checkbox(in line: String) -> (done: Bool, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("-"), let open = trimmed.firstIndex(of: "[") else { return nil }
        let marker = trimmed.index(after: open)
        guard marker < trimmed.endIndex, trimmed[marker] == " " || trimmed[marker] == "x" || trimmed[marker] == "X" else { return nil }
        let close = trimmed.index(after: marker)
        guard close < trimmed.endIndex, trimmed[close] == "]" else { return nil }
        return (trimmed[marker].lowercased() == "x", String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }
    private static func attachment(_ line: String, keys: [String]) -> String? {
        keys.first(where: { line.lowercased().hasPrefix($0.lowercased() + ":") }).map { String(line.dropFirst($0.count + 1)) }
    }
}

enum WorkflowError: LocalizedError { case notLocal, missing(String), invalidStep(Int, count: Int)
    var errorDescription: String? { switch self { case .notLocal: "Workflow is read-only; use_workflow first."; case .missing(let id): "No workflow '\(id)'. Call list_workflows."; case .invalidStep(let index, let count): "Workflow has \(count) steps; step \(index) does not exist." } }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
