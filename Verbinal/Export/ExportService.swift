// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
#if os(macOS)
import AppKit
#endif

/// Orchestrates exporting one or more modules into a timestamped bundle folder.
/// Writes Claude-friendly structure: `manifest.json` + `README.md` at the root,
/// one subdirectory per module.
///
/// Module concrete types (`ResearchExporter`, `SearchExporter`) live in their
/// respective feature modules — `ExportService` only sees the `ExportableModule`
/// protocol, so this file never needs editing when new exporters are added.
@Observable
@MainActor
final class ExportService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ExportService")

    var isExporting = false
    var lastExportURL: URL?
    var lastError: String?

    /// Export all supplied modules into a new timestamped folder inside `destination`.
    /// Returns the URL of the created bundle folder, or `nil` on failure.
    func exportAll(
        to destination: URL,
        modules: [ExportableModule],
        options: ExportOptions = ExportOptions()
    ) async -> URL? {
        isExporting = true
        lastError = nil
        defer { isExporting = false }

        let bundleURL = destination.appendingPathComponent(Self.bundleName(), isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            var manifestModules: [ExportManifest.Module] = []

            for module in modules {
                let output = try await module.export(options: options)
                let moduleDir = bundleURL.appendingPathComponent(module.moduleID, isDirectory: true)
                try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)

                var files: [String] = []

                // Sort filenames for deterministic, reproducible output.
                for filename in output.jsonFiles.keys.sorted() {
                    guard let data = output.jsonFiles[filename] else { continue }
                    let fileURL = moduleDir.appendingPathComponent(filename)
                    try data.write(to: fileURL, options: .atomic)
                    files.append("\(module.moduleID)/\(filename)")
                }

                for filename in output.markdownFiles.keys.sorted() {
                    guard let text = output.markdownFiles[filename] else { continue }
                    let fileURL = moduleDir.appendingPathComponent(filename)
                    try text.write(to: fileURL, atomically: true, encoding: .utf8)
                    files.append("\(module.moduleID)/\(filename)")
                }

                if options.includeFileCopies && !output.attachedFiles.isEmpty {
                    let filesDir = moduleDir.appendingPathComponent("files", isDirectory: true)
                    try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
                    for src in output.attachedFiles {
                        let dest = filesDir.appendingPathComponent(src.lastPathComponent)
                        try? FileManager.default.copyItem(at: src, to: dest)
                    }
                    files.append("\(module.moduleID)/files/")
                }

                manifestModules.append(
                    ExportManifest.Module(
                        id: module.moduleID,
                        displayName: module.displayName,
                        files: files.sorted(),
                        itemCounts: output.itemCounts
                    )
                )
            }

            // Write manifest.json — Claude hints derived from the actual files written.
            let allFiles = manifestModules.flatMap(\.files)
            let manifest = ExportManifest(
                exportVersion: "1.0",
                appName: "Verbinal",
                appVersion: Self.appVersion(),
                exportedAt: Date(),
                hostName: ProcessInfo.processInfo.hostName,
                modules: manifestModules,
                claudeHints: ExportManifest.ClaudeHints(
                    primaryContext: allFiles.first(where: { $0.hasSuffix(".md") }),
                    metadataSchema: allFiles.first(where: { $0.hasSuffix(".json") }),
                    readMeFirst: "README.md"
                )
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: bundleURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )

            // Write README.md
            let readme = Self.renderReadme(manifest: manifest)
            try readme.write(
                to: bundleURL.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )

            lastExportURL = bundleURL
            Self.logger.log("Export completed: \(bundleURL.path, privacy: .public)")
            return bundleURL

        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: bundleURL)
            return nil
        }
    }

    // MARK: - VOSpace upload

    #if os(macOS)
    /// Zip the bundle folder and upload it to VOSpace at `Verbinal-Exports/<name>.zip`.
    /// Creates the parent container if needed. Returns the remote path on success.
    func uploadBundleToVOSpace(
        bundleURL: URL,
        vospace: VOSpaceBrowserService,
        username: String
    ) async throws -> String {
        let zipURL = try Self.zipFolder(at: bundleURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        // Ensure the parent container exists (idempotent — VOSpace returns 409 on already-exists)
        do {
            try await vospace.createFolder(
                username: username,
                parentPath: "",
                folderName: "Verbinal-Exports"
            )
        } catch {
            // 409 (conflict) = folder already exists — expected. Log other errors for diagnostics.
            Self.logger.info("VOSpace folder creation note: \(error.localizedDescription, privacy: .public)")
        }

        let remotePath = "Verbinal-Exports/\(zipURL.lastPathComponent)"
        try await vospace.uploadFile(
            username: username,
            remotePath: remotePath,
            fileURL: zipURL
        )
        Self.logger.log("Uploaded bundle to VOSpace: \(remotePath, privacy: .public)")
        return remotePath
    }

    /// Zip a folder into a temporary file using NSFileCoordinator's built-in upload format.
    /// This avoids shelling out to /usr/bin/zip and works under the app sandbox.
    static func zipFolder(at url: URL) throws -> URL {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var resultURL: URL?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: url,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(url.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: tempZipURL, to: dest)
                resultURL = dest
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let resultURL else {
            throw NSError(
                domain: "ExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create zip archive"]
            )
        }
        return resultURL
    }
    #endif

    // MARK: - Helpers

    private static func bundleName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "Verbinal-Export-\(f.string(from: Date()))"
    }

    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private static func renderReadme(manifest: ExportManifest) -> String {
        let dateF = DateFormatter()
        dateF.dateStyle = .long
        dateF.timeStyle = .medium
        let dateStr = dateF.string(from: manifest.exportedAt)

        var md = "# Verbinal Export — \(dateStr)\n\n"
        md += "This bundle was exported from Verbinal v\(manifest.appVersion) on `\(manifest.hostName)`.\n"
        md += "It is structured for consumption by Claude, other LLMs, and human collaborators.\n\n"

        md += "## Contents\n\n"
        for module in manifest.modules {
            let counts = module.itemCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
            md += "- **\(module.displayName)** (`\(module.id)/`) — \(counts.isEmpty ? "no items" : counts)\n"
        }
        md += "\n"

        md += "## For Claude / LLM ingestion\n\n"
        if let primary = manifest.claudeHints.primaryContext {
            md += "1. Start with `manifest.json` to understand the bundle shape.\n"
            md += "2. Read `\(primary)` for human-readable per-item content.\n"
            if let schema = manifest.claudeHints.metadataSchema {
                md += "3. Cross-reference with `\(schema)` for full metadata.\n\n"
            } else {
                md += "\n"
            }
        }

        md += "### Suggested prompts\n\n"
        md += "- *\"Summarize the data in this export, grouped by module.\"*\n"
        md += "- *\"Which items stand out as needing further investigation?\"*\n"
        md += "- *\"List everything tagged `calibration` across all modules.\"*\n\n"

        md += "## Privacy note\n\n"
        md += "This bundle excludes all authentication tokens, Keychain entries, session state, "
        md += "and cached credentials. Only user-authored data and public CADC metadata are exported.\n"

        return md
    }
}
