// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Marks on FITS images, for agents: draw, list, change, pick out, remove,
/// clear, export. Marks are kept with the file (`MarkStore`) and drawn by
/// the viewer's `MarkOverlay`.
extension AppState {

    // MARK: - Resolving where

    /// The file and extension a mark tool acts on: `target` or the image on
    /// screen; `hdu` or the extension on screen (for a file not on screen,
    /// the primary HDU).
    @MainActor
    private func markTarget(_ args: MarkTargetArgs) throws -> (target: MarkStore.Target, tab: FITSViewerModel?) {
        if let path = args.target?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let url = URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(path))
            let tab = fitsTabHost.tab(showing: url).flatMap { $0.isLoaded ? $0 : nil }
            return (MarkStore.Target(file: url, hdu: args.hdu ?? tab?.selectedHDUIndex ?? 0), tab)
        }
        guard let tab = fitsTabHost.activeTab, tab.isLoaded, let file = tab.fileURL else {
            throw ToolFailureReason.targetNotResolved("no FITS image is on screen — open one, or name a `target` file")
        }
        return (MarkStore.Target(file: file, hdu: args.hdu ?? tab.selectedHDUIndex), tab)
    }

    /// Every extension's marks of a file when neither `hdu` is named nor the
    /// file is on screen — or `allHdus` asks for it.
    @MainActor
    private func markTargets(_ args: MarkTargetArgs) throws -> (file: String, targets: [MarkStore.Target]) {
        let resolved = try markTarget(args)
        let file = resolved.target.file
        let everyHDU = args.allHdus == true || (args.hdu == nil && resolved.tab == nil && args.target != nil)
        return (file, everyHDU ? marks.targets(of: URL(fileURLWithPath: file)) : [resolved.target])
    }

    private func markFailure(_ error: any Error) -> ToolFailureReason {
        guard let failure = error as? MarkStore.Failure else { return .backendError("\(error)") }
        if case .notFound = failure { return .unknownTarget(failure.message) }
        return .invalidArgument(failure.message)
    }

    private func noteMark(_ tool: String, _ summary: String) {
        agentsService.activityStore.append(.live(kind: tool, summary: summary, origin: .external(clientID: tool)))
    }

    // MARK: - Tools

    func makeAnnotateFITSTool() -> MarkTool<MarkTools.Annotate, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "annotate_fits",
            description: "Draw a mark on a FITS image: a circle or box around a source, a callout with a leader to a label, or a label alone. Give the position as 0-based FITS pixels (x, y) or on the sky (raDeg, decDeg) — prefer the sky when the file has WCS, so the mark points at the same place in another image of the field. Sizes are in the position's own units (pixels, or degrees on the sky), so a mark keeps its size on the subject as the view zooms. The mark is kept with the file and extension, and shown as an agent's.",
            schema: """
            {
              "type": "object",
              "properties": {
            \(MarkFields.schemaProperties),
            \(MarkTools.targetProperties)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let kind = try Mark.Kind.parse(args.fields.kind ?? "circle")
                .orThrow(ToolFailureReason.invalidArgument("kind must be circle, rect, callout or text"))
            guard let anchor = try args.fields.anchor() else {
                throw ToolFailureReason.invalidArgument("give the position as x and y, or as raDeg and decDeg")
            }
            let extent = try args.fields.extent()
            let style = try args.fields.style(from: .agentDefault)
            return try await MainActor.run {
                let (target, tab) = try self.markTarget(args.target)
                if anchor.space == .sky, let tab, tab.wcs == nil {
                    throw ToolFailureReason.invalidArgument("this image has no WCS, so a sky position has no place on it — give x and y")
                }
                let mark = Mark(id: self.marks.newID(on: target), kind: kind, anchor: anchor, extent: extent,
                                text: args.fields.text ?? "", labelOffsetX: args.fields.labelOffsetX,
                                labelOffsetY: args.fields.labelOffsetY, author: .agent, style: style, createdAt: Date())
                do { try self.marks.add(mark, to: target) } catch { throw self.markFailure(error) }
                self.noteMark("annotate_fits", "Marked \(mark.text.isEmpty ? mark.kind.rawValue : mark.text)")
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, mark: MarkView(mark))
            }
        }
    }

    func makeListFITSAnnotationsTool() -> MarkReadTool<MarkTargetArgs, MarkTools.Listing> {
        MarkReadTool(definition: AIToolDefinition.withStaticSchema(
            name: "list_fits_annotations",
            description: "The marks on a FITS file: the image on screen (its extension) by default, or `target` — a file need not be open. `allHdus` lists every extension's; for a file not on screen without `hdu`, every extension's is the default.",
            schema: """
            {
              "type": "object",
              "properties": {
            \(MarkTools.targetProperties),
                "allHdus": { "type": "boolean" }
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let (file, targets) = try self.markTargets(args)
                let entries = targets.flatMap { t in self.marks.marks(on: t).map { MarkTools.Listing.Entry(hdu: t.hdu, mark: MarkView($0)) } }
                return MarkTools.Listing(file: file, count: entries.count, marks: entries)
            }
        }
    }

    func makeUpdateAnnotationTool() -> MarkTool<MarkTools.Update, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "update_annotation",
            description: "Change a mark by id (from list_fits_annotations): move it (x, y or raDeg, decDeg), resize it, relabel it, move a callout's label, restyle it. Only what you give changes.",
            schema: """
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id": { "type": "string" },
                \(MarkTools.viewerProperty),
            \(MarkFields.schemaProperties),
            \(MarkTools.targetProperties)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let anchor = try args.fields.anchor()
            let extent = try args.fields.extent()
            let kind = try args.fields.kind.map {
                try Mark.Kind.parse($0).orThrow(ToolFailureReason.invalidArgument("kind must be circle, rect, callout or text"))
            }
            return try await MainActor.run {
                let (target, _) = try self.markTarget(args.target)
                let current = self.marks.marks(on: target).first { $0.id == args.id }
                let style = try args.fields.style(from: current?.effectiveStyle ?? .agentDefault)
                let mark: Mark
                do {
                    mark = try self.marks.update(args.id, on: target) { m in
                        if let kind { m.kind = kind }
                        if let anchor { m.anchor = anchor }
                        if let extent { m.extent = extent }
                        if let text = args.fields.text { m.text = text }
                        if let dx = args.fields.labelOffsetX { m.labelOffsetX = dx }
                        if let dy = args.fields.labelOffsetY { m.labelOffsetY = dy }
                        if let style { m.style = style }
                    }
                } catch { throw self.markFailure(error) }
                self.noteMark("update_annotation", "Changed mark \(mark.id)")
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, mark: MarkView(mark))
            }
        }
    }

    func makeSelectAnnotationTool() -> MarkTool<MarkTools.ByID, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "select_annotation",
            description: "Pick out a mark on the image on screen — highlighted, and the view centred on it — so the person sees which one you mean. Omit `id` to let go of whatever is picked out.",
            schema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                \(MarkTools.viewerProperty)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let (target, tab) = try self.markTarget(MarkTargetArgs())
                guard let id = args.id else {
                    self.marks.selected = nil
                    return MarkChange(applied: true, file: target.file, hdu: target.hdu)
                }
                guard let mark = self.marks.marks(on: target).first(where: { $0.id == id }) else {
                    throw ToolFailureReason.unknownTarget("no mark \"\(id)\" on the image on screen")
                }
                self.marks.selected = (target, id)
                if let tab, let point = tab.displayPoint(mark.anchor) {
                    tab.centerOnPixel(point, canvasSize: tab.lastCanvasSize)
                }
                self.navigateTo(.fitsViewer)
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, mark: MarkView(mark))
            }
        }
    }

    func makeRemoveAnnotationTool() -> MarkTool<MarkTools.ByID, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "remove_annotation",
            description: "Remove one mark by id — list_fits_annotations first if you are not certain which id is which.",
            schema: """
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id": { "type": "string" },
                \(MarkTools.viewerProperty),
            \(MarkTools.targetProperties)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let (target, _) = try self.markTarget(MarkTargetArgs(target: args.target, hdu: args.hdu))
                do { try self.marks.remove(args.id ?? "", from: target) } catch { throw self.markFailure(error) }
                self.noteMark("remove_annotation", "Removed mark \(args.id ?? "")")
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, removed: 1)
            }
        }
    }

    func makeClearAnnotationsTool() -> MarkTool<MarkTargetArgs, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "clear_annotations",
            description: "Remove every mark on a file's extension (the one on screen by default), or on all its extensions with `allHdus`.",
            schema: """
            {
              "type": "object",
              "properties": {
            \(MarkTools.targetProperties),
                "allHdus": { "type": "boolean" }
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let (file, targets) = try self.markTargets(args)
                let removed = self.marks.clear(targets)
                self.noteMark("clear_annotations", "Cleared \(removed) mark\(removed == 1 ? "" : "s")")
                return MarkChange(applied: true, file: file, hdu: targets.count == 1 ? targets[0].hdu : nil, removed: removed)
            }
        }
    }

    struct ExportMarksArgs: Decodable, Sendable {
        var format: String?
        var target: String?
        var hdu: Int?
        var allHdus: Bool?
    }

    func makeExportAnnotationsTool() -> MarkReadTool<ExportMarksArgs, MarkTools.Exported> {
        MarkReadTool(definition: AIToolDefinition.withStaticSchema(
            name: "export_annotations",
            description: "A file's marks as a DS9 region file (default; sky marks in fk5 with sizes in arcseconds, pixel marks in DS9's 1-based image pixels) or as JSON grouped by extension. A DS9 region file is for one image, so give `hdu` when marks are on several extensions — or use json. The file need not be open. Returns the text; nothing is written to disk.",
            schema: """
            {
              "type": "object",
              "properties": {
                "format": { "type": "string", "enum": ["ds9", "json"] },
            \(MarkTools.targetProperties),
                "allHdus": { "type": "boolean" }
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let format = MarkExport.Format(rawValue: args.format ?? "ds9") ?? .ds9
            let (file, extensions): (String, [MarkExport.Extension]) = try await MainActor.run {
                let (file, targets) = try self.markTargets(MarkTargetArgs(target: args.target, hdu: args.hdu, allHdus: args.allHdus))
                return (file, targets.map { MarkExport.Extension(hdu: $0.hdu, marks: self.marks.marks(on: $0)) }
                    .filter { !$0.marks.isEmpty })
            }
            let content: String
            switch format {
            case .ds9:
                guard extensions.count <= 1 else {
                    throw ToolFailureReason.invalidArgument(
                        "marks are on extensions \(extensions.compactMap { $0.hdu.map(String.init) }.joined(separator: ", ")) — a DS9 region file is for one image: give hdu, or use format json")
                }
                content = MarkExport.ds9(extensions.first?.marks ?? [])
            case .json:
                content = String(decoding: try MarkExport.json(extensions, file: file), as: UTF8.self)
            }
            return MarkTools.Exported(format: format.rawValue, count: extensions.reduce(0) { $0 + $1.marks.count }, content: content)
        }
    }
}

extension Optional {
    /// The value, or `error` thrown.
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
