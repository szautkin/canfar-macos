// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Opening files: archive downloads into the FITS / Cube viewers, the
/// NAXIS≥3 "Open as…" choice, and the local file-browser panel.
extension AppState {
    // MARK: - Viewer opens

    func makeOpenFITSFileTool(store: ObservationStore) -> OpenFITSFileTool {
        let activity = agentsService.activityStore
        return OpenFITSFileTool(openFITS: { [weak self] rawID in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let obs = await MainActor.run { store.observation(matching: rawID) }
            guard let obs else {
                throw ToolFailureReason.observationNotFound(id: rawID, localPath: nil)
            }
            let url = try Self.resolveAccessibleFileURL(for: obs).url
            // View-state ops don't run through the proposal flow, so
            // we don't have an `OperationOrigin` from a context. Fall
            // back to a synthetic external origin tagged with the
            // tool name — the activity feed surfaces it as a "live"
            // entry so the user sees the breadcrumb even though no
            // proposal was queued.
            let origin: OperationOrigin = .external(clientID: "open_fits_file")
            do {
                try await self.loadFITSNow(url: url)
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_fits_file",
                        summary: "Opened FITS file: \(obs.observationID) (\(obs.collection))",
                        origin: origin
                    ))
                }
            } catch let e as AstronomyOpenError {
                throw ToolFailureReason.backendError("failed to open FITS: \(e.message)")
            }
            return (observationID: obs.observationID, localPath: obs.localPath)
        })
    }

    /// Cube-viewer twin of `makeOpenFITSFileTool` — resolves the downloaded
    /// observation's URL and routes it into the Cube Viewer (its own mode).
    func makeOpenCubeTool(store: ObservationStore) -> OpenCubeTool {
        let activity = agentsService.activityStore
        return OpenCubeTool(openCube: { [weak self] rawID in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let obs = await MainActor.run { store.observation(matching: rawID) }
            guard let obs else {
                throw ToolFailureReason.observationNotFound(id: rawID, localPath: nil)
            }
            let url = try Self.resolveAccessibleFileURL(for: obs).url
            let origin: OperationOrigin = .external(clientID: "open_cube")
            do {
                try await self.loadCubeNow(url: url)
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_cube",
                        summary: "Opened cube: \(obs.observationID) (\(obs.collection))",
                        origin: origin
                    ))
                }
            } catch let e as AstronomyOpenError {
                throw ToolFailureReason.backendError("failed to open cube: \(e.message)")
            }
            return (observationID: obs.observationID, localPath: obs.localPath)
        })
    }

    func makeChooseViewerTool() -> ChooseViewerTool {
        let activity = agentsService.activityStore
        return ChooseViewerTool(choose: { [weak self] viewer in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            guard let url = await self.pendingViewerChoiceURL else {
                throw ToolFailureReason.invalidArgument(
                    "No Open as… sheet is showing. Call get_current_view — pendingViewerChoice is set when a NAXIS≥3 file needs a 2D vs 3D pick.")
            }
            let path = LocalFolderAccessStore.userFacingPath(for: url)
            let name = url.lastPathComponent
            await MainActor.run { self.pendingViewerChoiceURL = nil }
            switch viewer {
            case "fits":
                do {
                    try await self.loadFITSNow(url: url)
                } catch let e as AstronomyOpenError {
                    throw ToolFailureReason.backendError(e.message)
                }
                await MainActor.run {
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Opened \(name) in FITS Viewer",
                        origin: .external(clientID: "choose_viewer")))
                }
                return ChooseViewerTool.Output(
                    applied: true, viewer: "fits", path: path,
                    note: "Opened in the 2D FITS Viewer.")
            case "cube":
                do {
                    try await self.loadCubeNow(url: url)
                } catch let e as AstronomyOpenError {
                    throw ToolFailureReason.backendError(e.message)
                }
                await MainActor.run {
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Opened \(name) in Cube Viewer",
                        origin: .external(clientID: "choose_viewer")))
                }
                return ChooseViewerTool.Output(
                    applied: true, viewer: "cube", path: path,
                    note: "Opened in the 3D Cube Viewer.")
            case "dismiss":
                await MainActor.run {
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Dismissed Open as… for \(name)",
                        origin: .external(clientID: "choose_viewer")))
                }
                return ChooseViewerTool.Output(
                    applied: true, viewer: "dismiss", path: path,
                    note: "Closed the Open as… sheet without opening the file.")
            default:
                throw ToolFailureReason.invalidArgument(
                    "viewer must be 'fits', 'cube', or 'dismiss'")
            }
        })
    }

    // MARK: - Local files

    func makeListLocalFolderTool() -> ListLocalFolderTool {
        ListLocalFolderTool(list: { [weak self] args in
            let requested = args.path ?? LocalFolderAccessStore.userFacingDownloadsRoot.path
            let candidates = LocalFolderAccessStore.candidateURLs(for: requested, isDirectory: true)
            let displayPath = LocalFolderAccessStore.userFacingPath(
                for: candidates.first ?? URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(requested), isDirectory: true))
            var allowed: [URL] = []
            if let self {
                for url in candidates {
                    if await self.localFolderAccess.hasAccess(to: url) {
                        allowed.append(url)
                    }
                }
                if allowed.isEmpty {
                    throw ToolFailureReason.notReadable(
                        "'\(displayPath)' is outside the app sandbox. Only ~/Downloads and folders the user has granted are readable. Ask the user to grant this folder in Storage, then retry — `request_folder_access` cannot show a picker from an MCP client.")
                }
            } else {
                allowed = candidates
            }
            var listedURL: URL?
            var byName: [String: URL] = [:]
            var lastListError: Error?
            var sawMissing = true
            for url in allowed {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                sawMissing = false
                guard isDir.boolValue else {
                    throw ToolFailureReason.invalidArgument("'\(displayPath)' is a file, not a folder")
                }
                do {
                    let items = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])
                    if listedURL == nil { listedURL = url }
                    for item in items where byName[item.lastPathComponent] == nil {
                        byName[item.lastPathComponent] = item
                    }
                } catch {
                    lastListError = error
                }
            }
            guard listedURL != nil || !byName.isEmpty else {
                if let lastListError {
                    throw ToolFailureReason.notReadable(
                        "cannot read '\(displayPath)': \(lastListError.localizedDescription)")
                }
                if sawMissing {
                    throw ToolFailureReason.unknownTarget("no folder at '\(displayPath)'")
                }
                throw ToolFailureReason.notReadable("cannot read '\(displayPath)'")
            }
            let contents = Array(byName.values)
            let sorted = contents.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            var entries: [ListLocalFolderTool.Output.Entry] = []
            var truncated = false
            for item in sorted {
                if entries.count >= 500 { truncated = true; break }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let fits = !isDirectory && FileHelper.isFITS(item.pathExtension)
                if args.supportedOnly == true && !isDirectory && !fits { continue }
                entries.append(.init(
                    name: item.lastPathComponent,
                    isDirectory: isDirectory,
                    sizeBytes: (values?.fileSize).map(Int64.init),
                    isFITS: fits))
            }
            return .init(
                path: listedURL.map { LocalFolderAccessStore.userFacingPath(for: $0) } ?? displayPath,
                entries: entries,
                truncated: truncated)
        })
    }

    func makeOpenLocalFileTool() -> OpenLocalFileTool {
        let activity = agentsService.activityStore
        return OpenLocalFileTool(open: { [weak self] path, viewer in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let url = LocalFolderAccessStore.readableURL(for: path, directory: false)
                ?? LocalFolderAccessStore.resolveSandboxPath(
                    URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(path)))
            let displayPath = LocalFolderAccessStore.userFacingPath(for: url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolFailureReason.unknownTarget("No file at '\(displayPath)'")
            }
            guard FileHelper.isFITS(url.pathExtension) else {
                throw ToolFailureReason.invalidArgument("'\(url.lastPathComponent)' is not a FITS file")
            }
            if await !self.localFolderAccess.hasAccess(to: url) {
                throw ToolFailureReason.notReadable(
                    "'\(displayPath)' is outside the app sandbox — ask the user to grant its folder in Storage, or move it to ~/Downloads.")
            }
            let choice = viewer.flatMap { AppState.AstronomyViewerChoice(rawValue: $0) }
            let outcome: AppState.AstronomyOpenOutcome
            do {
                outcome = try await self.openAstronomyFITSAwaitingChoice(url: url, viewer: choice)
            } catch let e as AppState.AstronomyOpenError {
                throw ToolFailureReason.backendError(e.message)
            }
            let name = url.lastPathComponent
            switch outcome {
            case .openedFITS:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Opened \(name) in FITS Viewer",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(applied: true, path: displayPath, viewer: "fits",
                             pendingViewerChoice: false, note: nil)
            case .openedCube:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Opened \(name) in Cube Viewer",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(applied: true, path: displayPath, viewer: "cube",
                             pendingViewerChoice: false, note: nil)
            case .awaitingViewerChoice:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Asked how to open \(name)",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(
                    applied: true, path: displayPath, viewer: nil,
                    pendingViewerChoice: true,
                    note: AppState.viewerChoiceAgentNote(filename: name))
            }
        })
    }

    func makeRequestFolderAccessTool() -> RequestFolderAccessTool {
        let activity = agentsService.activityStore
        return RequestFolderAccessTool(request: { [weak self] startingPath in
            guard let self else { return .cancelled }
            return await MainActor.run {
                let start = startingPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                guard let granted = try? self.localFolderAccess.grantAccess(startingAt: start) else {
                    return .cancelled
                }
                activity.append(.live(
                    kind: "request_folder_access",
                    summary: "Granted folder access: \(granted.path)",
                    origin: .external(clientID: "request_folder_access")))
                return .granted(granted.path)
            }
        })
    }
}
