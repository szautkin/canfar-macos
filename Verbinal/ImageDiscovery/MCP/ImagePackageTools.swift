// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What is inside the images that have been probed: the names packages
/// actually go by, and one image's contents.

// MARK: - search_packages

/// The vocabulary of what is installed. A search for "spectroscopy" matches
/// no package, though images carry the packages that do it, and a zero-hit
/// search reads as "no image does that"; this says what the packages are CALLED, so the
/// next search is one that can match.
struct SearchPackagesTool: JSONReadTool {
    /// Names returned per ecosystem: enough to choose from, few enough to read.
    static let maxPerEcosystem = 40
    static let ecosystems = ["python", "r", "dpkg", "rpm", "apk"]

    struct Args: Decodable, Sendable {
        let query: String
        var ecosystem: String?
    }

    struct Output: Encodable, Sendable {
        let query: String
        let count: Int
        let matches: [Matches]
        let message: String?

        struct Matches: Encodable, Sendable, Equatable {
            let ecosystem: String
            /// How many matched; `names` lists the first `maxPerEcosystem`.
            let count: Int
            let names: [String]
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "search_packages",
        description: "Find what a package is actually CALLED, across every image that has been probed. Use it BEFORE find_images_with_packages when working from a subject rather than a package name: a subject such as \"spectroscopy\" names no package, while the packages that do it (specutils, for one) are what images carry, and a zero-hit search reads as \"no image does that\". Matches anywhere in the name, per ecosystem (python, r, dpkg, rpm, apk), the shortest — usually the package itself — first.",
        schema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "description": "Part of a package name." },
            "ecosystem": { "type": "string", "enum": ["any", "python", "r", "dpkg", "rpm", "apk"], "description": "Default any." }
          },
          "additionalProperties": false
        }
        """#
    )

    let vocabulary: @Sendable () async -> AllPackages

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolFailureReason.invalidArgument("query is required") }
        let ecosystem = (args.ecosystem ?? "any").trimmingCharacters(in: .whitespaces).lowercased()
        guard ecosystem == "any" || Self.ecosystems.contains(ecosystem) else {
            throw ToolFailureReason.invalidArgument("ecosystem must be one of any, \(Self.ecosystems.joined(separator: ", ")) — got '\(args.ecosystem ?? "")'")
        }
        let all = await vocabulary()
        if all.isEmpty {
            return Output(query: query, count: 0, matches: [],
                          message: "no images have been probed yet — run discover_image_packages on an image first")
        }
        let matches = Self.matches(query, in: all, ecosystems: ecosystem == "any" ? Self.ecosystems : [ecosystem])
        let count = matches.reduce(0) { $0 + $1.count }
        return Output(query: query, count: count, matches: matches,
                      message: count == 0 ? "no probed image has a package with that in its name" : nil)
    }

    static func matches(_ query: String, in all: AllPackages, ecosystems: [String]) -> [Output.Matches] {
        let names: [String: Set<String>] = ["python": all.python, "r": all.r, "dpkg": all.dpkg, "rpm": all.rpm, "apk": all.apk]
        return ecosystems.compactMap { ecosystem in
            let found = (names[ecosystem] ?? [])
                .filter { $0.range(of: query, options: .caseInsensitive) != nil }
                .sorted { ($0.count, $0.lowercased()) < ($1.count, $1.lowercased()) }
            return found.isEmpty ? nil : Output.Matches(ecosystem: ecosystem, count: found.count, names: Array(found.prefix(maxPerEcosystem)))
        }
    }
}

// MARK: - describe_image

/// What is inside one probed image: to choose between the images
/// find_images_with_packages returned — the one with the newer astropy, or
/// the one that also has CASA.
struct DescribeImageTool: JSONReadTool {
    /// Packages listed per section; the median image here holds over six hundred.
    static let maxPerSection = 50

    struct Args: Decodable, Sendable {
        let imageID: String
        var filter: String?
    }

    struct Output: Encodable, Sendable {
        let imageID: String
        let os: String
        let kernel: String?
        let pythonVersion: String?
        let capabilities: [String]
        let sections: [Section]
        let probeNotes: String?
        let capturedAt: String
        let message: String?

        struct Section: Encodable, Sendable, Equatable {
            let ecosystem: String
            /// How many there are (that match `filter`); `packages` lists the first `maxPerSection`.
            let count: Int
            let packages: [Package]
        }

        struct Package: Encodable, Sendable, Equatable {
            let name: String
            let version: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "describe_image",
        description: "What is inside a container image that has been probed: its OS, kernel, Python version, capabilities, and its packages by ecosystem (Python per environment, R, dpkg, rpm, apk) with versions. Use it to choose between the images find_images_with_packages returned — the one with the newer astropy, or the one that also has CASA. `filter` keeps only packages whose name contains it. Only probed images can be described; discover_image_packages probes one. (get_image_manifest gives the counts alone.)",
        schema: #"""
        {
          "type": "object",
          "required": ["imageID"],
          "properties": {
            "imageID": { "type": "string", "description": "The full image reference, as list_session_images reports it." },
            "filter": { "type": "string", "description": "Only list packages whose name contains this." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// The image's manifest when it has been probed successfully.
    let manifest: @Sendable (String) async -> ImageManifest?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let id = args.imageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolFailureReason.invalidArgument("imageID is required") }
        guard let manifest = await manifest(id) else {
            throw ToolFailureReason.unknownTarget(
                "'\(id)' has not been probed — run discover_image_packages on it first, or use find_images_with_packages to find one that has been")
        }
        return Self.describe(manifest, filter: args.filter ?? "")
    }

    static func describe(_ manifest: ImageManifest, filter rawFilter: String) -> Output {
        let filter = rawFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections: [Output.Section] = manifest.sections.compactMap { section in
            let kept = filter.isEmpty ? section.packages : section.packages.filter { $0.name.range(of: filter, options: .caseInsensitive) != nil }
            guard !kept.isEmpty else { return nil }
            return Output.Section(ecosystem: section.ecosystem, count: kept.count,
                                  packages: kept.prefix(maxPerSection).map { Output.Package(name: $0.name, version: $0.version) })
        }
        func known(_ text: String) -> String? { text.isEmpty || text == "unknown" ? nil : text }
        return Output(
            imageID: manifest.imageID,
            os: [manifest.osFamily, manifest.osVersion].compactMap(known).joined(separator: " "),
            kernel: known(manifest.kernel),
            pythonVersion: known(manifest.pythonVersion),
            capabilities: manifest.capabilities,
            sections: sections,
            probeNotes: manifest.probeNotes.flatMap { $0.isEmpty ? nil : $0 },
            capturedAt: ISO8601DateFormatter().string(from: manifest.capturedAt),
            message: !filter.isEmpty && sections.isEmpty ? "nothing in this image matches '\(filter)'" : nil)
    }
}
