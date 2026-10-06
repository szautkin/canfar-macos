// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

/// The map of the tool surface, so an agent can choose among 150 tools
/// without reading them all: `list_apps` (the areas), `describe_app(app:)`
/// (one area's tools), `search_tools` (a tool by what it does) and `man`
/// (one tool's page). They help an agent choose; they do not shrink
/// `tools/list`, which a client reads on connect.
///
/// The areas are ``AIGuideCatalog``'s — the AI Guide screen's too — and the
/// tools are ``PublishedManifest``'s, exactly as `tools/list` gives them.
enum ToolMap {

    struct Area: Encodable, Sendable, Equatable {
        let id: String
        let title: String
        let summary: String
        let toolCount: Int
    }

    struct Entry: Encodable, Sendable, Equatable {
        let name: String
        let summary: String
        let appID: String
        let app: String
    }

    /// Areas that have tools, in the catalogue's order.
    static func areas(_ tools: [ToolDefinitionWire]) -> [Area] {
        let counts = Dictionary(grouping: tools, by: { category(of: $0.name).id }).mapValues(\.count)
        return (AIGuideCatalog.categories + [AIGuideCatalog.guides]).compactMap { c in
            counts[c.id].map { Area(id: c.id, title: c.title, summary: c.summary, toolCount: $0) }
        }
    }

    /// One area's tools, by name.
    static func entries(inArea id: String, _ tools: [ToolDefinitionWire]) -> [Entry] {
        tools.filter { category(of: $0.name).id == id }
            .sorted { $0.name < $1.name }
            .map(entry)
    }

    /// Tools whose name or description holds most of the query's words
    /// (all of one or two, two of three…), name hits first. "cube spectrum"
    /// finds `probe_cube_spectrum`: matched as one phrase it found nothing.
    static func search(_ query: String, area: String?, in tools: [ToolDefinitionWire]) -> [Entry] {
        let words = queryWords(query)
        let needed = words.count - words.count / 3
        let scored: [(tool: ToolDefinitionWire, found: Int, inName: Int)] = tools.compactMap { tool in
            let name = tool.name.lowercased()
            let text = tool.description.lowercased()
            let found = words.filter { name.contains($0) || text.contains($0) }.count
            guard found >= needed else { return nil }
            if let area, category(of: tool.name).id.caseInsensitiveCompare(area) != .orderedSame { return nil }
            return (tool, found, words.filter { name.contains($0) }.count)
        }
        return scored
            .sorted { ($0.found, $0.inName, $1.tool.name) > ($1.found, $1.inName, $0.tool.name) }
            .map { entry($0.tool) }
    }

    /// A description's first sentence — enough to choose by; `man` has the rest.
    static func summary(of description: String) -> String {
        let first = description.range(of: ". ").map { String(description[..<$0.lowerBound]) + "." } ?? description
        return first.count <= 200 ? first : String(first.prefix(200)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func category(of name: String) -> AIGuideCatalog.Category {
        let id = AIGuideCatalog.categoryID(forTool: name)
        return AIGuideCatalog.categories.first { $0.id == id } ?? AIGuideCatalog.guides
    }

    private static func entry(_ tool: ToolDefinitionWire) -> Entry {
        let area = category(of: tool.name)
        return Entry(name: tool.name, summary: summary(of: tool.description), appID: area.id, app: area.title)
    }

    /// Words that say nothing about what a tool does.
    private static let filler: Set<String> = [
        "a", "an", "the", "of", "on", "in", "at", "to", "for", "and", "or", "with", "by", "from", "into",
        "is", "are", "be", "it", "its", "my", "me", "how", "do", "can", "what", "this", "that", "some", "please",
    ]

    /// Letters, digits and underscores, so a tool's name is one word. A
    /// query of nothing but filler is taken as written.
    static func queryWords(_ query: String) -> [String] {
        let lowered = query.lowercased()
        var seen = Set<String>()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { $0.count > 1 && !filler.contains($0) && seen.insert($0).inserted }
        return words.isEmpty ? [lowered.trimmingCharacters(in: .whitespaces)] : words
    }
}

// MARK: - list_apps

struct ListAppsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let appCount: Int
        let toolCount: Int
        let apps: [ToolMap.Area]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_apps",
        description: "START HERE when you do not know which tool you need. Lists the app's areas — Search, FITS, Cube Viewer, Storage, Sessions and the rest — with what each is for and how many tools it has. Then call describe_app with the area's id to get just its tools, or man for one tool's arguments.",
        schema: #"{"type":"object","properties":{},"additionalProperties":false}"#
    )

    let published: @Sendable () async -> [ToolDefinitionWire]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let tools = await published()
        let apps = ToolMap.areas(tools)
        return Output(appCount: apps.count, toolCount: tools.count, apps: apps)
    }
}

// MARK: - search_tools

struct SearchToolsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let query: String
        var app: String?
    }

    struct Output: Encodable, Sendable {
        let query: String
        let count: Int
        let tools: [ToolMap.Entry]
        let message: String?
    }

    /// Enough to choose from; fewer than the list it saves reading.
    static let maxMatches = 25

    let definition = AIToolDefinition.withStaticSchema(
        name: "search_tools",
        description: "Find a tool by what it DOES, when you do not know its area. Matches the words of the query — most of them must appear — against tool names and descriptions, name matches first, and gives each hit's area. Then call the tool, man for its arguments, or describe_app for its area. Use list_apps for the shape of the whole app.",
        schema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "minLength": 1, "description": "What you are trying to do, or part of a tool's name." },
            "app": { "type": "string", "description": "Only this area's tools (an id from list_apps)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let published: @Sendable () async -> [ToolDefinitionWire]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolFailureReason.invalidArgument("query is required") }
        let matches = ToolMap.search(query, area: args.app, in: await published())
        let message: String? = matches.isEmpty
            ? "nothing matched — try list_apps for the areas, or a plainer word"
            : matches.count > Self.maxMatches ? "showing the first \(Self.maxMatches)" : nil
        return Output(query: query, count: matches.count, tools: Array(matches.prefix(Self.maxMatches)), message: message)
    }
}

// MARK: - man

struct ManTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let tool: String
    }

    struct Output: Encodable, Sendable {
        let found: Bool
        let tool: String
        let app: String?
        let description: String?
        /// The tool's own schema, verbatim.
        let inputSchema: JSONValue?
        let didYouMean: [String]
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "man",
        description: "Read one tool's full entry — its description and complete argument schema — by name. list_apps, describe_app and search_tools answer with names and summaries, so this is how to get the arguments of the one you picked without calling it wrong first. An unknown name answers with the closest ones.",
        schema: #"""
        {
          "type": "object",
          "required": ["tool"],
          "properties": {
            "tool": { "type": "string", "minLength": 1, "description": "The tool's name, e.g. \"fits_goto_coordinate\"." }
          },
          "additionalProperties": false
        }
        """#
    )

    let published: @Sendable () async -> [ToolDefinitionWire]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let wanted = args.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = await published()
        if let hit = tools.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return Output(found: true, tool: hit.name, app: ToolMap.category(of: hit.name).id,
                          description: hit.description, inputSchema: hit.inputSchema,
                          didYouMean: [], message: nil)
        }
        // A typo or a half-remembered name: show what does exist.
        let lowered = wanted.lowercased()
        let wantedWords = Set(lowered.split(separator: "_").filter { $0.count >= 3 })
        // Names holding the whole guess first, then ones sharing a word.
        let near = tools.map(\.name).compactMap { name -> (name: String, whole: Bool)? in
            let whole = name.contains(lowered) || lowered.contains(name)
            guard whole || !wantedWords.isDisjoint(with: name.split(separator: "_")) else { return nil }
            return (name, whole)
        }
        .sorted { ($0.whole ? 0 : 1, $0.name) < ($1.whole ? 0 : 1, $1.name) }
        .prefix(5).map(\.name)
        return Output(
            found: false, tool: wanted, app: nil, description: nil, inputSchema: nil,
            didYouMean: Array(near),
            message: near.isEmpty
                ? "no tool named \"\(wanted)\". Use search_tools to find one by what it does."
                : "no tool named \"\(wanted)\"; did you mean one of these?")
    }
}
