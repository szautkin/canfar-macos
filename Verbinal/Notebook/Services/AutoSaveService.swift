// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Auto-saves notebook state every 30 seconds to protect against crashes.
@Observable
@MainActor
final class AutoSaveService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AutoSave")
    private static let interval: TimeInterval = 30
    private var timer: Task<Void, Never>?
    private var lastSavedSource: String?

    static var autoSaveDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Verbinal/AutoSave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start(model: NotebookModel) {
        stop()
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled, model.isDirty else { continue }

                let currentSource = model.cells.map(\.source).joined()
                guard currentSource != lastSavedSource else { continue }

                do {
                    try autoSave(model: model)
                    lastSavedSource = currentSource
                } catch {
                    Self.logger.warning("Auto-save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func cleanup(for model: NotebookModel) {
        let path = autoSavePath(for: model)
        try? FileManager.default.removeItem(at: path)
    }

    private func autoSave(model: NotebookModel) throws {
        let path = autoSavePath(for: model)
        let doc = NotebookDocument(
            metadata: NotebookDocMetadata(kernelspec: KernelSpec(), languageInfo: LanguageInfo()),
            cells: model.cells.map { cell in
                NotebookCellData(
                    cellType: cell.cellType == .markdown ? "markdown" : "code",
                    source: NotebookParser.splitSourceLines(cell.source),
                    id: NotebookParser.generateCellId()
                )
            }
        )
        let data = try NotebookParser.serialize(doc)
        try data.write(to: path, options: .atomic)
        Self.logger.debug("Auto-saved to \(path.lastPathComponent)")
    }

    private func autoSavePath(for model: NotebookModel) -> URL {
        let name = model.filePath?.deletingPathExtension().lastPathComponent ?? "untitled"
        let hash = String(model.id.uuidString.prefix(8))
        return Self.autoSaveDirectory.appendingPathComponent("\(name)-\(hash).autosave.ipynb")
    }

    /// Find orphaned autosave files from previous crashes.
    static func findRecoverableFiles() -> [(url: URL, name: String, date: Date)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: autoSaveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "ipynb" && $0.lastPathComponent.contains(".autosave.") }
            .compactMap { url -> (url: URL, name: String, date: Date)? in
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let name = url.lastPathComponent
                    .replacingOccurrences(of: ".autosave.ipynb", with: "")
                    .components(separatedBy: "-").dropLast().joined(separator: "-")
                return (url: url, name: name.isEmpty ? "Untitled" : name, date: attrs?.contentModificationDate ?? Date.distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    static func discardAll() {
        let files = findRecoverableFiles()
        for file in files {
            try? FileManager.default.removeItem(at: file.url)
        }
    }
}
