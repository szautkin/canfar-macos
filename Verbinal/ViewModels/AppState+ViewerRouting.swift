// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit
#if os(macOS)
import AppKit
#endif
#if canImport(MetricKit)
import MetricKit
#endif

/// Opening a FITS file in the viewer it needs: the 2D viewer, the cube, or the person's choice.
extension AppState {
    /// Agent-facing copy when the "Open as…" sheet is showing. Shared by
    /// `get_current_view`, `open_local_file`, and `open_vospace_file`.
    nonisolated static func viewerChoiceAgentNote(filename: String) -> String {
        "An Open as… sheet is showing for \(filename). Call choose_viewer(viewer: \"fits\") for the 2D FITS Viewer, choose_viewer(viewer: \"cube\") for the 3D Cube Viewer, or choose_viewer(viewer: \"dismiss\") to close the sheet."
    }

    /// Agent-facing copy for an open still loading at the deadline. Shared
    /// by every tool that opens a file.
    nonisolated static func stillLoadingAgentNote(filename: String, viewer: AstronomyViewerChoice) -> String {
        let (name, read) = viewer == .fits
            ? ("FITS Viewer", "get_fits_view (isOpen)")
            : ("Cube Viewer", "get_cube_view")
        return "\(filename) is still loading in the \(name) — it is large, not failed. Do not open it again (a second open only switches to its tab); check \(read) or list_open_tabs until it is there."
    }

    /// Open a FITS file in the right viewer. Plain 2D images go to the FITS
    /// Viewer; NAXIS≥3 files prompt for 2D vs Cube (spectral cubes default
    /// to Cube). Detection reads only the header. Fire-and-forget for UI
    /// clicks: the viewer keeps a tab that fails to load, with its error and
    /// Retry. MCP callers use `openAstronomyFITSAwaitingChoice`, which waits
    /// for the load and reports its failure instead.
    @discardableResult
    func openAstronomyFITS(url: URL, viewer: AstronomyViewerChoice? = nil) -> Task<Void, Never> {
        Task {
            switch await astronomyRoute(for: url, viewer: viewer) {
            case .fits?: dispatch(.openFITS(url: url))
            case .cube?: dispatch(.openCube(url: url))
            case nil: pendingViewerChoiceURL = url
            }
        }
    }

    /// Which viewer a file opens in — decided once for the UI and the
    /// agent paths. Nil: ask (the "Open as…" sheet).
    func astronomyRoute(for url: URL, viewer: AstronomyViewerChoice?) async -> AstronomyViewerChoice? {
        if let viewer { return viewer }
        return await Self.fitsIsCube(url) ? nil : .fits
    }

    #if os(macOS)
    /// Agent path: shows the viewer, opens `url` there, and waits for the
    /// pixels — or until `agentOpenWait`, answering `.loading` while the
    /// load carries on. A failed load leaves no dead tab and throws.
    func loadForAgent(url: URL, in viewer: AstronomyViewerChoice) async throws -> AstronomyOpenOutcome {
        switch viewer {
        case .fits:
            pendingFITSURL = nil
            return try await loadNow(url: url, in: fitsTabHost, mode: .fitsViewer, as: viewer)
        case .cube:
            pendingCubeURL = nil
            return try await loadNow(url: url, in: cubeTabHost, mode: .cubeViewer, as: viewer)
        }
    }

    private enum LoadRace: Sendable {
        case finished(failure: String?)
        case stillLoading
    }

    func loadNow<Host: ViewerTabHosting>(
        url: URL, in host: Host, mode: AppMode, as viewer: AstronomyViewerChoice
    ) async throws -> AstronomyOpenOutcome {
        navigateTo(mode)
        let race = await withHardDeadline(
            seconds: agentOpenWait,
            cancelsWork: false,
            onDeadline: { LoadRace.stillLoading },
            work: { @MainActor in .finished(failure: await host.openFileDiscardingFailure(url: url)) })
        switch race {
        case .finished(nil): return .opened(viewer)
        case .finished(let failure?): throw AstronomyOpenError(message: failure)
        case .stillLoading: return .loading(viewer)
        }
    }
    #endif

    /// Error from a viewer load that failed after the file was handed off.
    struct AstronomyOpenError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Same routing as `openAstronomyFITS`, but waits for the header-only
    /// cube detection so MCP tools can return `pendingViewerChoice`, and
    /// for the load (up to `agentOpenWait`) so `opened: true` is honest.
    @discardableResult
    func openAstronomyFITSAwaitingChoice(
        url: URL,
        viewer: AstronomyViewerChoice? = nil
    ) async throws -> AstronomyOpenOutcome {
        guard let viewer = await astronomyRoute(for: url, viewer: viewer) else {
            pendingViewerChoiceURL = url
            return .awaitingViewerChoice
        }
        #if os(macOS)
        return try await loadForAgent(url: url, in: viewer)
        #else
        dispatch(viewer == .fits ? .openFITS(url: url) : .openCube(url: url))
        return .opened(viewer)
        #endif
    }

    func openPendingViewerChoiceAsFITS() {
        guard let url = pendingViewerChoiceURL else { return }
        pendingViewerChoiceURL = nil
        dispatch(.openFITS(url: url))
    }

    func openPendingViewerChoiceAsCube() {
        guard let url = pendingViewerChoiceURL else { return }
        pendingViewerChoiceURL = nil
        dispatch(.openCube(url: url))
    }

    /// Header-only test for whether a FITS file is a spectral cube (NAXIS≥3),
    /// so it routes to the Cube Viewer. Internal so the Research detail view can
    /// label its Open button with the same decision the router will make.
    nonisolated static func fitsIsCube(_ url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = try? LocalFileCubeSource(url: url),
              let hdus = try? await FITSCube.parseStructure(source: source) else { return false }
        return !FITSCube.findCubeHDUs(hdus).isEmpty
    }
}
