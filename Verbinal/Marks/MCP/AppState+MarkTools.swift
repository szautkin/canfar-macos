// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Marks on the FITS viewer and the cube, for agents: draw, list, change,
/// pick out, remove, clear, export. Marks are kept with the file
/// (`MarkStore`) and each viewer draws its own (`MarkOverlay`).
extension AppState {

    // MARK: - Resolving where

    /// The marks a tool acts on, and the tab showing their file, if one is.
    struct ResolvedMarkTarget {
        let viewer: MarkViewer
        let target: MarkStore.Target
        var fits: FITSViewerModel?
        var cube: CubeViewerModel?

        var isOnScreen: Bool { fits != nil || cube != nil }
    }

    /// `target` or the file on screen in the viewer; for FITS, `hdu` or the
    /// extension on screen (for a file not on screen, the primary HDU).
    @MainActor
    private func markTarget(_ args: MarkTargetArgs) throws -> ResolvedMarkTarget {
        let viewer = try MarkViewer.parse(args.viewer)
        let path = args.target?.trimmingCharacters(in: .whitespaces)
        let named = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: LocalFolderAccessStore.expandedPath($0)) }
        switch viewer {
        case .fits:
            if let named {
                let tab = fitsTabHost.tab(showing: named).flatMap { $0.isLoaded ? $0 : nil }
                return ResolvedMarkTarget(viewer: .fits, target: .init(file: named, hdu: args.hdu ?? tab?.selectedHDUIndex ?? 0),
                                          fits: tab)
            }
            guard let tab = fitsTabHost.activeTab, tab.isLoaded, let file = tab.fileURL else {
                throw ToolFailureReason.targetNotResolved("no FITS image is on screen — open one, or name a `target` file")
            }
            return ResolvedMarkTarget(viewer: .fits, target: .init(file: file, hdu: args.hdu ?? tab.selectedHDUIndex), fits: tab)
        case .cube:
            guard args.hdu == nil, args.allHdus == nil else {
                throw ToolFailureReason.invalidArgument("hdu and allHdus are for FITS marks — a cube's marks are on its channels")
            }
            if let named {
                let tab = cubeTabHost.tab(showing: named).flatMap { $0.isLoaded ? $0 : nil }
                return ResolvedMarkTarget(viewer: .cube, target: .init(file: named, hdu: nil), cube: tab)
            }
            let cube = cubeViewer
            guard cube.hasData, let file = cube.fileURL else {
                throw ToolFailureReason.targetNotResolved("no cube is on screen — open one, or name a `target` file")
            }
            return ResolvedMarkTarget(viewer: .cube, target: .init(file: file, hdu: nil), cube: cube)
        }
    }

    /// A FITS file's every extension when neither `hdu` is named nor the
    /// file is on screen — or `allHdus` asks for it.
    @MainActor
    private func markTargets(_ args: MarkTargetArgs) throws -> (file: String, targets: [MarkStore.Target]) {
        let resolved = try markTarget(args)
        let file = resolved.target.file
        let everyHDU = args.allHdus == true || (args.hdu == nil && !resolved.isOnScreen && args.target != nil)
        guard resolved.viewer == .fits, everyHDU else { return (file, [resolved.target]) }
        return (file, marks.targets(of: URL(fileURLWithPath: file)).filter { $0.hdu != nil })
    }

    /// A position the open file has no place for is refused, not stored
    /// and never drawn.
    @MainActor
    private func refuseUnplaceable(_ anchor: Mark.Anchor, on resolved: ResolvedMarkTarget) throws {
        if anchor.space == .sky, let tab = resolved.fits, tab.wcs == nil {
            throw ToolFailureReason.invalidArgument("this image has no WCS, so a sky position has no place on it — give x and y")
        }
        if anchor.space == .data, let cube = resolved.cube, !(0..<cube.nz).contains(Int(anchor.z.rounded())) {
            throw ToolFailureReason.invalidArgument("channel \(Int(anchor.z.rounded())) is not in this cube — it has channels 0–\(cube.nz - 1)")
        }
    }

    private func markFailure(_ error: any Error) -> ToolFailureReason {
        guard let failure = error as? MarkStore.Failure else { return .backendError("\(error)") }
        if case .notFound = failure { return .unknownTarget(failure.message) }
        return .invalidArgument(failure.message)
    }

    private func noteMark(_ tool: String, _ summary: String) {
        agentsService.activityStore.append(.live(kind: tool, summary: summary, origin: .external(clientID: tool)))
    }

    private nonisolated static let kindRefusal = ToolFailureReason.invalidArgument("kind must be circle, rect, callout or text")

    // MARK: - Draw

    func makeAnnotateFITSTool() -> MarkTool<MarkTools.Annotate, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "annotate_fits",
            description: "Draw a mark on a FITS image: a circle or box around a source, a callout with a leader to a label, or a label alone. Give the position as 0-based FITS pixels (x, y) or on the sky (raDeg, decDeg) — prefer the sky when the file has WCS, so the mark points at the same place in another image of the field. Sizes are in the position's own units (pixels, or degrees on the sky), so a mark keeps its size on the subject as the view zooms. The mark is kept with the file and extension, and shown as an agent's.",
            schema: """
            {
              "type": "object",
              "properties": {
            \(MarkFields.fitsPosition)
            \(MarkFields.shapeProperties),
            \(MarkTools.targetProperties)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await self.annotate(args, in: .fits, tool: "annotate_fits")
        }
    }

    func makeAnnotateCubeTool() -> MarkTool<MarkTools.Annotate, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "annotate_cube",
            description: "Draw a mark in the cube viewer. A cube mark lives on a CHANNEL: it is drawn on the slice showing that channel, not on every slice. Positions are 0-based voxels (x, y) with the channel; sizes are in voxels. The mark is kept with the file, and shown as an agent's.",
            schema: """
            {
              "type": "object",
              "required": ["x", "y", "channel"],
              "properties": {
            \(MarkFields.cubePosition)
            \(MarkFields.shapeProperties),
            \(MarkTools.cubeTargetProperty)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await self.annotate(args, in: .cube, tool: "annotate_cube")
        }
    }

    private func annotate(_ args: MarkTools.Annotate, in viewer: MarkViewer, tool: String) async throws -> MarkChange {
        let kind = try Mark.Kind.parse(args.fields.kind ?? "circle").orThrow(Self.kindRefusal)
        guard let anchor = try args.fields.anchor(for: viewer) else {
            throw ToolFailureReason.invalidArgument(viewer == .cube
                ? "give the position as x, y and channel"
                : "give the position as x and y, or as raDeg and decDeg")
        }
        let extent = try args.fields.extent()
        let style = try args.fields.style(from: .agentDefault)
        let targetArgs = args.target.in(viewer)
        return try await MainActor.run {
            let resolved = try self.markTarget(targetArgs)
            try self.refuseUnplaceable(anchor, on: resolved)
            let target = resolved.target
            let mark = Mark(id: self.marks.newID(on: target), kind: kind, anchor: anchor, extent: extent,
                            text: args.fields.text ?? "", labelOffsetX: args.fields.labelOffsetX,
                            labelOffsetY: args.fields.labelOffsetY, author: .agent, style: style, createdAt: Date())
            do { try self.marks.add(mark, to: target) } catch { throw self.markFailure(error) }
            self.noteMark(tool, "Marked \(mark.text.isEmpty ? mark.kind.rawValue : mark.text)")
            return MarkChange(applied: true, file: target.file, hdu: target.hdu, mark: MarkView(mark))
        }
    }

    // MARK: - List

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
            return try await self.listMarks(args.in(.fits))
        }
    }

    func makeListCubeAnnotationsTool() -> MarkReadTool<MarkTargetArgs, MarkTools.Listing> {
        MarkReadTool(definition: AIToolDefinition.withStaticSchema(
            name: "list_cube_annotations",
            description: "The marks on a cube — the one on screen by default, or `target`; the file need not be open. Each mark gives its voxel and channel.",
            schema: """
            {
              "type": "object",
              "properties": {
            \(MarkTools.cubeTargetProperty)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await self.listMarks(args.in(.cube))
        }
    }

    private func listMarks(_ args: MarkTargetArgs) async throws -> MarkTools.Listing {
        try await MainActor.run {
            let (file, targets) = try self.markTargets(args)
            let entries = targets.flatMap { t in self.marks.marks(on: t).map { MarkTools.Listing.Entry(hdu: t.hdu, mark: MarkView($0)) } }
            return MarkTools.Listing(file: file, count: entries.count, marks: entries)
        }
    }

    // MARK: - Change

    func makeUpdateAnnotationTool() -> MarkTool<MarkTools.Update, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "update_annotation",
            description: "Change a mark by id (from list_fits_annotations or list_cube_annotations): move it (x, y — or raDeg, decDeg on a FITS image; channel on a cube), resize it, relabel it, move a callout's label, restyle it. Only what you give changes.",
            schema: """
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id": { "type": "string" },
                \(MarkTools.viewerProperty),
            \(MarkFields.anyPosition)
            \(MarkFields.shapeProperties),
            \(MarkTools.targetProperties)
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let viewer = try MarkViewer.parse(args.target.viewer)
            let extent = try args.fields.extent()
            let kind = try args.fields.kind.map { try Mark.Kind.parse($0).orThrow(Self.kindRefusal) }
            return try await MainActor.run {
                let resolved = try self.markTarget(args.target)
                let target = resolved.target
                let current = self.marks.marks(on: target).first { $0.id == args.id }
                let anchor = try args.fields.anchor(for: viewer,
                                                    currentChannel: current?.anchor.space == .data ? current?.anchor.z : nil)
                // A cube mark moved to another channel only.
                let channel = viewer == .cube && anchor == nil ? args.fields.channel.map(Double.init) : nil
                if let anchor { try self.refuseUnplaceable(anchor, on: resolved) }
                if let channel, var moved = current?.anchor {
                    moved.z = channel
                    try self.refuseUnplaceable(moved, on: resolved)
                }
                let style = try args.fields.style(from: current?.effectiveStyle ?? .agentDefault)
                let mark: Mark
                do {
                    mark = try self.marks.update(args.id, on: target) { m in
                        if let kind { m.kind = kind }
                        if let anchor { m.anchor = anchor }
                        if let channel { m.anchor.z = channel }
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
            description: "Pick out a mark on the image or cube on screen — highlighted, and the view centred on it (a cube goes to the mark's channel) — so the person sees which one you mean. Omit `id` to let go of whatever is picked out.",
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
                let resolved = try self.markTarget(MarkTargetArgs(viewer: args.target.viewer))
                let target = resolved.target
                guard let id = args.id else {
                    self.marks.selected = nil
                    return MarkChange(applied: true, file: target.file, hdu: target.hdu)
                }
                guard let mark = self.marks.marks(on: target).first(where: { $0.id == id }) else {
                    throw ToolFailureReason.unknownTarget("no mark \"\(id)\" on the \(resolved.viewer == .cube ? "cube" : "image") on screen")
                }
                self.marks.selected = (target, id)
                if let tab = resolved.fits {
                    if let point = tab.displayPoint(mark.anchor) { tab.centerOnPixel(point, canvasSize: tab.lastCanvasSize) }
                    self.navigateTo(.fitsViewer)
                } else if let cube = resolved.cube {
                    cube.centreSlice(onVoxel: mark.anchor.x, mark.anchor.y, channel: Int(mark.anchor.z.rounded()))
                    self.navigateTo(.cubeViewer)
                }
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, mark: MarkView(mark))
            }
        }
    }

    // MARK: - Remove

    func makeRemoveAnnotationTool() -> MarkTool<MarkTools.ByID, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "remove_annotation",
            description: "Remove one mark by id — list the marks first if you are not certain which id is which.",
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
            let id = try args.id.orThrow(ToolFailureReason.invalidArgument("id is required"))
            return try await MainActor.run {
                let target = try self.markTarget(args.target).target
                do { try self.marks.remove(id, from: target) } catch { throw self.markFailure(error) }
                self.noteMark("remove_annotation", "Removed mark \(id)")
                return MarkChange(applied: true, file: target.file, hdu: target.hdu, removed: 1)
            }
        }
    }

    func makeClearAnnotationsTool() -> MarkTool<MarkTargetArgs, MarkChange> {
        MarkTool(definition: AIToolDefinition.withStaticSchema(
            name: "clear_annotations",
            description: "Remove every mark on a FITS file's extension (the one on screen by default; all of them with `allHdus`), or on a cube with viewer cube.",
            schema: """
            {
              "type": "object",
              "properties": {
                \(MarkTools.viewerProperty),
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

    // MARK: - Export

    struct ExportMarksArgs: Decodable, Sendable {
        let format: String?
        let target: MarkTargetArgs

        private enum Keys: String, CodingKey { case format }
        init(from decoder: Decoder) throws {
            format = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .format)
            target = try MarkTargetArgs(from: decoder)
        }
    }

    func makeExportAnnotationsTool() -> MarkReadTool<ExportMarksArgs, MarkTools.Exported> {
        MarkReadTool(definition: AIToolDefinition.withStaticSchema(
            name: "export_annotations",
            description: "A file's marks as a DS9 region file (default; sky marks in fk5 with sizes in arcseconds, pixel and voxel marks in DS9's 1-based image pixels) or as JSON grouped by extension, with each cube mark's channel. A DS9 region file is for one image, so give `hdu` when a FITS file's marks are on several extensions — or use json. The file need not be open. Returns the text; nothing is written to disk.",
            schema: """
            {
              "type": "object",
              "properties": {
                "format": { "type": "string", "enum": ["ds9", "json"] },
                \(MarkTools.viewerProperty),
            \(MarkTools.targetProperties),
                "allHdus": { "type": "boolean" }
              },
              "additionalProperties": false
            }
            """)) { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let format = MarkExport.Format(rawValue: args.format ?? "ds9") ?? .ds9
            let (file, extensions): (String, [MarkExport.Extension]) = try await MainActor.run {
                let (file, targets) = try self.markTargets(args.target)
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

extension MarkTargetArgs {
    /// The same place, in `viewer`'s marks.
    func `in`(_ viewer: MarkViewer) -> MarkTargetArgs {
        var args = self
        args.viewer = viewer.rawValue
        return args
    }
}

extension Optional {
    /// The value, or `error` thrown.
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
