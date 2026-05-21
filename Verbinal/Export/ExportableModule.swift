// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Protocol

/// Any feature module that has user data to export conforms to this protocol.
/// Exporters should produce Claude-friendly output: markdown for human/LLM content,
/// JSON for structured metadata, stable keys (`publisherID` wherever possible) for cross-reference.
///
/// Exporters run on the main actor because the underlying stores (`ObservationStore`,
/// `ObservationNoteStore`, etc.) are `@Observable` and accessed from SwiftUI views.
///
/// Dependency direction: `Export/` owns this protocol and is a leaf — features
/// (Research, Search, …) depend on it, not the other way around.
@MainActor
protocol ExportableModule {
    /// Stable module identifier (e.g. "research", "search"). Used as subdirectory name.
    var moduleID: String { get }
    /// Human-readable module name (e.g. "Research").
    var displayName: String { get }
    /// Build the export payload for this module.
    func export(options: ExportOptions) async throws -> ExportModuleOutput
}

/// Output bundle from a single module's export.
struct ExportModuleOutput {
    /// Filenames (relative to module subdirectory) → JSON data.
    var jsonFiles: [String: Data] = [:]
    /// Filenames (relative to module subdirectory) → markdown content.
    var markdownFiles: [String: String] = [:]
    /// External files to copy into the bundle (when options.includeFileCopies is true).
    var attachedFiles: [URL] = []
    /// Summary counts shown in the manifest (e.g. ["observations": 42, "notes": 12]).
    var itemCounts: [String: Int] = [:]
}

/// User-configurable export behavior.
struct ExportOptions {
    var includeFileCopies: Bool = false
    var includeNotes: Bool = true
    var includeSearchHistory: Bool = true
}

// MARK: - Shared Encoding

/// Shared JSON/ISO8601 configuration used by every module's exporter so all
/// bundle files share a single schema (pretty-printed, sorted keys, ISO-8601 dates).
enum ExportEncoding {
    // ISO8601DateFormatter is documented thread-safe; mark
    // `nonisolated(unsafe)` so the strict-concurrency check
    // doesn't flag this read-only static across actor boundaries.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - Manifest

/// Machine-readable index written to the bundle root as `manifest.json`.
/// Matches the schema in `dev_info/dev_plans/export-module-2026-04-09.md`.
struct ExportManifest: Codable {
    struct Module: Codable {
        var id: String
        var displayName: String
        var files: [String]
        var itemCounts: [String: Int]
    }

    struct ClaudeHints: Codable {
        /// Best markdown file for LLM ingestion (first .md file across all modules).
        var primaryContext: String?
        /// First JSON file across all modules, used as a schema reference.
        var metadataSchema: String?
        var readMeFirst: String
    }

    var exportVersion: String
    var appName: String
    var appVersion: String
    var exportedAt: Date
    var hostName: String
    var modules: [Module]
    var claudeHints: ClaudeHints
}
