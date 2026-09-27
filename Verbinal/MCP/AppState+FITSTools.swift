// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// FITS viewer: header/WCS reads, view control, and the parity batch
/// (HDU, auto-cut, blink, tab sync, search at crosshair).
extension AppState {
    // MARK: - FITS domain

    func makeGetFITSHeaderTool(store: ObservationStore) -> GetFITSHeaderTool {
        GetFITSHeaderTool(resolve: { id in
            try await Self.resolveFITS(id: id, store: store)
        })
    }

    func makeGetFITSWCSTool(store: ObservationStore) -> GetFITSWCSTool {
        var tool = GetFITSWCSTool(resolve: { id in
            try await Self.resolveFITS(id: id, store: store)
        })
        tool.onScreenHDU = { [weak self] url in
            guard let self else { return nil }
            return await MainActor.run {
                self.fitsTabHost.tab(showing: url).flatMap { $0.isLoaded ? $0.selectedHDUIndex : nil }
            }
        }
        return tool
    }

    /// Open the local FITS file for a downloaded observation, parse it,
    /// and return the snapshot. Tries the security-scoped bookmark
    /// *before* `fileExists` on the stored path — a sandbox miss on the
    /// user-facing Downloads string is not "file gone" (2026-08-28 re-test).
    nonisolated private static func resolveFITS(id: String, store: ObservationStore) async throws -> ResolvedFITS? {
        let obs = await MainActor.run { store.observation(matching: id) }
        guard let obs else {
            throw ToolFailureReason.observationNotFound(id: id, localPath: nil)
        }
        let access = try resolveAccessibleFileURL(for: obs)
        defer {
            if access.didStart { access.url.stopAccessingSecurityScopedResource() }
        }
        do {
            let file = try FITSParser.parse(url: access.url)
            return ResolvedFITS(observationID: obs.observationID, file: file)
        } catch {
            throw ToolFailureReason.backendError("FITS parse: \(error.localizedDescription)")
        }
    }

    /// Bookmark first, then sandbox-mapped path candidates. Never require
    /// `DownloadedObservation.fileExists` before attempting the bookmark.
    nonisolated static func resolveAccessibleFileURL(for obs: DownloadedObservation) throws -> (url: URL, didStart: Bool) {
        if let bookmark = obs.bookmarkData {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &stale)
                let didStart = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) {
                    return (url, didStart)
                }
                if didStart { url.stopAccessingSecurityScopedResource() }
            } catch {
                // Stale bookmark — fall through to path candidates.
            }
        }
        if let url = obs.resolvedReadableURL {
            return (url, false)
        }
        throw ToolFailureReason.observationNotFound(id: obs.id.uuidString, localPath: obs.localPath)
    }

    // MARK: - FITS viewer control

    func makeGetFITSViewTool() -> GetFITSViewTool {
        GetFITSViewTool(snapshot: { [weak self] in
            guard let self else { return Self.emptyFITSView() }
            return await self.fitsViewSnapshot()
        })
    }

    func makeSetFITSViewTool() -> SetFITSViewTool {
        SetFITSViewTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await self.applyFITSView(args)
        })
    }

    func makeFITSGotoCoordinateTool() -> FITSGotoCoordinateTool {
        FITSGotoCoordinateTool(goTo: { [weak self] ra, dec in
            guard let self else { return nil }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, tab.wcs != nil,
                      let hdu = tab.selectedHDU else { return nil }
                switch tab.goToCoordinate(ra: ra, dec: dec) {
                case .centred:
                    return .centred
                case .offImage(let x, let y):
                    return .offImage(x: x, y: y, whereItFalls: FITSViewerModel.whereItFalls(
                        x: x, y: y, width: hdu.header.naxis1, height: hdu.header.naxis2))
                case .unplaceable:
                    return .unplaceable
                }
            }
        })
    }

    func makeProbeFITSPixelTool() -> ProbeFITSPixelTool {
        ProbeFITSPixelTool(probe: { [weak self] x, y in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, let hdu = tab.selectedHDU else {
                    throw ToolFailureReason.targetNotResolved("No FITS image is open in the viewer")
                }
                guard let result = tab.probePixel(x: x, y: y) else {
                    throw ToolFailureReason.invalidArgument(
                        "pixel (\(x), \(y)) outside \(hdu.header.naxis1)×\(hdu.header.naxis2)")
                }
                return ProbeFITSPixelTool.Output(
                    x: x, y: y, value: result.value, raDeg: result.ra, decDeg: result.dec)
            }
        })
    }

    func makeListFITSBookmarksTool() -> ListFITSBookmarksTool {
        ListFITSBookmarksTool(snapshot: { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                let iso = ISO8601DateFormatter()
                return self.fitsBookmarks.bookmarks.map {
                    ListFITSBookmarksTool.Entry(
                        id: $0.id.uuidString, label: $0.label,
                        raDeg: $0.ra, decDeg: $0.dec,
                        sourceFilePath: $0.sourceFilePath,
                        savedAtISO: iso.string(from: $0.savedAt))
                }
            }
        })
    }

    func makeListOpenTabsTool() -> ListOpenTabsTool {
        ListOpenTabsTool(snapshot: { [weak self] in
            guard let self else {
                return ListOpenTabsTool.Output(
                    fitsTabs: [], activeFITSTabIndex: nil, cubeOpen: false, cubeFileName: nil,
                    cubeTabs: [], activeCubeTabIndex: nil)
            }
            return await MainActor.run {
                let host = self.fitsTabHost
                let tabs = host.tabPaths.enumerated().map { index, path in
                    ListOpenTabsTool.Output.Tab(
                        index: index, path: path, isActive: index == host.activeTabIndex)
                }
                let cube = self.cubeViewer
                return ListOpenTabsTool.Output(
                    fitsTabs: tabs,
                    activeFITSTabIndex: host.tabs.isEmpty ? nil : host.activeTabIndex,
                    cubeOpen: cube.hasData,
                    cubeFileName: cube.hasData ? cube.fileName : nil,
                    cubeTabs: self.cubeTabHost.tabPaths.enumerated().map {
                        .init(index: $0.offset, path: $0.element, isActive: $0.offset == self.cubeTabHost.activeTabIndex)
                    },
                    activeCubeTabIndex: self.cubeTabHost.activeTabIndex)
            }
        })
    }

    func makeCloseActiveTabTool() -> CloseActiveTabTool {
        let activity = agentsService.activityStore
        return CloseActiveTabTool(close: { [weak self] kind in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard kind == "fits" else { return "Unknown tab kind '\(kind)' — only \"fits\" tabs can be closed" }
                let host = self.fitsTabHost
                guard !host.tabs.isEmpty else { return "No FITS tabs are open" }
                host.closeActiveTab()
                activity.append(.live(
                    kind: "close_active_tab", summary: "Closed the active FITS tab",
                    origin: .external(clientID: "close_active_tab")))
                return nil
            }
        })
    }

    /// `isOpen: false` snapshot. Tabs whose load failed still list their
    /// paths so `openTabPaths` stays index-aligned with `activeTabIndex`.
    private nonisolated static func emptyFITSView(
        openTabPaths: [String] = [], activeTabIndex: Int? = nil
    ) -> GetFITSViewTool.Output {
        GetFITSViewTool.Output(
            isOpen: false, filePath: nil, hduIndex: nil, imageWidth: nil, imageHeight: nil,
            stretch: nil, colormap: nil, minCut: nil, maxCut: nil, zoom: nil,
            rotationRadians: nil, crosshair: nil,
            openTabPaths: openTabPaths, activeTabIndex: activeTabIndex)
    }

    private func fitsViewSnapshot() -> GetFITSViewTool.Output {
        let host = fitsTabHost
        let paths = host.tabPaths
        guard let tab = host.activeTab, tab.isLoaded, let hdu = tab.selectedHDU else {
            return Self.emptyFITSView(
                openTabPaths: paths,
                activeTabIndex: host.tabs.isEmpty ? nil : host.activeTabIndex)
        }
        var crosshair: GetFITSViewTool.Output.Crosshair?
        if let point = tab.crosshairPixel {
            // Same array indices `probe_fits_pixel` takes, so an agent can
            // probe the pixel under the crosshair without converting.
            let pixel = FITSViewerModel.arrayPixel(atDisplay: point, naxis2: hdu.header.naxis2)
            crosshair = .init(
                x: pixel.x, y: pixel.y,
                raDeg: tab.crosshairRADeg, decDeg: tab.crosshairDecDeg,
                value: tab.crosshairValue)
        }
        return GetFITSViewTool.Output(
            isOpen: true,
            filePath: tab.fileURL?.path,
            hduIndex: tab.selectedHDUIndex,
            imageWidth: hdu.header.naxis1,
            imageHeight: hdu.header.naxis2,
            stretch: tab.renderParams.stretch.rawValue,
            colormap: tab.renderParams.colormap.rawValue,
            minCut: Double(tab.renderParams.minCut),
            maxCut: Double(tab.renderParams.maxCut),
            zoom: tab.viewport.zoom,
            rotationRadians: tab.viewport.rotation,
            crosshair: crosshair,
            openTabPaths: paths,
            activeTabIndex: host.activeTabIndex)
    }

    private func applyFITSView(_ args: SetFITSViewTool.Args) -> String? {
        let host = fitsTabHost
        if let idx = args.tabIndex {
            guard host.tabs.indices.contains(idx) else {
                return host.tabs.isEmpty
                    ? "No FITS tabs are open"
                    : "tabIndex \(idx) out of range 0…\(host.tabs.count - 1)"
            }
            host.activeTabIndex = idx
        }
        guard let tab = host.activeTab else { return "No FITS file is open in the viewer" }

        var needsRender = false
        if let s = args.stretch {
            guard let mode = FITSRenderParams.StretchMode(rawValue: s) else { return "Unknown stretch '\(s)'" }
            tab.renderParams.stretch = mode
            needsRender = true
        }
        if let c = args.colormap {
            guard let map = FITSRenderParams.ColormapType(rawValue: c) else { return "Unknown colormap '\(c)'" }
            tab.renderParams.colormap = map
            needsRender = true
        }
        let lo = args.minCut.map(Float.init) ?? tab.renderParams.minCut
        let hi = args.maxCut.map(Float.init) ?? tab.renderParams.maxCut
        if args.minCut != nil || args.maxCut != nil {
            guard lo < hi else { return "minCut must be < maxCut" }
            tab.renderParams.minCut = lo
            tab.renderParams.maxCut = hi
            needsRender = true
        }
        if needsRender { tab.renderImage() }

        if let z = args.zoom { tab.setZoom(z) }
        if args.fitToWindow == true {
            guard tab.lastCanvasSize.width > 0 else {
                return "The FITS viewer canvas hasn't been laid out yet — open the FITS Viewer first"
            }
            tab.fitToWindow(canvasSize: tab.lastCanvasSize)
        }
        if args.northUp == true { tab.applyNorthUp() }

        agentsService.activityStore.append(.live(
            kind: "set_fits_view", summary: "Adjusted the FITS view",
            origin: .external(clientID: "set_fits_view")))
        return nil
    }

    // MARK: - FITS viewer parity (HDU, auto-cut, blink, sync, export)

    func makeSelectHDUTool() -> SelectHDUTool {
        let activity = agentsService.activityStore
        return SelectHDUTool(select: { [weak self] index in
            guard let self else { return "App state unavailable" }
            // Validate on the main actor, then run the (async, main-actor)
            // HDU switch outside the synchronous run block.
            let validated: (tab: FITSViewerModel?, error: String?) = await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, let file = tab.file else {
                    return (nil, "No FITS file is open in the viewer")
                }
                guard file.hdus.indices.contains(index) else {
                    return (nil, "hduIndex \(index) out of range 0…\(file.hdus.count - 1)")
                }
                guard file.hdus[index].isImage else {
                    return (nil, "HDU \(index) is not an image HDU")
                }
                return (tab, nil)
            }
            if let message = validated.error { return message }
            guard let tab = validated.tab else { return "No FITS file is open in the viewer" }
            await tab.selectHDU(index)
            await MainActor.run {
                activity.append(.live(
                    kind: "select_hdu",
                    summary: "Selected HDU \(index)",
                    origin: .external(clientID: "select_hdu")))
            }
            return nil
        })
    }

    func makeFITSAutoCutTool() -> FITSAutoCutTool {
        let activity = agentsService.activityStore
        return FITSAutoCutTool(autoCut: { [weak self] in
            guard let self else { return nil }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, !tab.pixels.isEmpty else {
                    return nil
                }
                let cuts = FITSParser.autoCut(pixels: tab.pixels)
                tab.renderParams.minCut = cuts.min
                tab.renderParams.maxCut = cuts.max
                tab.renderImage()
                activity.append(.live(
                    kind: "fits_auto_cut",
                    summary: "Auto-computed display cuts",
                    origin: .external(clientID: "fits_auto_cut")))
                return FITSAutoCutTool.Cuts(min: Double(cuts.min), max: Double(cuts.max))
            }
        })
    }

    func makeStartBlinkTool() -> StartBlinkTool {
        let activity = agentsService.activityStore
        return StartBlinkTool(start: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.tabs.count >= 2 else {
                    return .rejected("Blink needs at least 2 open FITS tabs")
                }
                let tabA = args.tabA ?? 0
                let tabB = args.tabB ?? 1
                guard host.tabs.indices.contains(tabA), host.tabs.indices.contains(tabB) else {
                    return .rejected("tab index out of range 0…\(host.tabs.count - 1)")
                }
                guard tabA != tabB else { return .rejected("tabA and tabB must differ") }
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                if self.currentMode != .fitsViewer { self.navigateTo(.fitsViewer) }
                host.startBlink(tabA: tabA, tabB: tabB)
                guard host.isBlinking else { return .rejected("Blink failed to start") }
                activity.append(.live(
                    kind: "start_blink",
                    summary: "Started blink: tab \(tabA) vs tab \(tabB)",
                    origin: .external(clientID: "start_blink")))
                return .started(.init(
                    tabA: tabA, tabB: tabB,
                    alignedWithWCS: host.blinkTransform != nil))
            }
        })
    }

    func makeSetBlinkTool() -> SetBlinkTool {
        let activity = agentsService.activityStore
        return SetBlinkTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.isBlinking else {
                    return "No blink session is running — call start_blink first"
                }
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                if let show = args.show {
                    if show == "a" { host.showBlinkA() } else { host.showBlinkB() }
                }
                // Applied after `show` so an explicit paused value wins
                // over show's implicit pause.
                if let paused = args.paused, paused != host.isBlinkPaused {
                    host.toggleBlinkPause()
                }
                activity.append(.live(
                    kind: "set_blink",
                    summary: "Adjusted the blink session",
                    origin: .external(clientID: "set_blink")))
                return nil
            }
        })
    }

    func makeStopBlinkTool() -> StopBlinkTool {
        let activity = agentsService.activityStore
        return StopBlinkTool(stop: { [weak self] in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.isBlinking else { return "No blink session is running" }
                host.stopBlink()
                activity.append(.live(
                    kind: "stop_blink",
                    summary: "Stopped the blink session",
                    origin: .external(clientID: "stop_blink")))
                return nil
            }
        })
    }

    func makeBlinkFITSTabsTool() -> BlinkFITSTabsTool {
        BlinkFITSTabsTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                let action = args.action ?? (args.partnerTab == nil ? "start" : "start")
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                switch action {
                case "stop":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    host.stopBlink()
                case "pause":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    if !host.isBlinkPaused { host.toggleBlinkPause() }
                case "resume":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    if host.isBlinkPaused { host.toggleBlinkPause() }
                case "start":
                    guard host.tabs.count >= 2 else { return .rejected("Blink needs at least 2 open FITS tabs") }
                    let partner = args.partnerTab ?? (host.activeTabIndex == 0 ? 1 : 0)
                    guard host.tabs.indices.contains(partner), partner != host.activeTabIndex else {
                        return .rejected("partnerTab must identify a different open FITS tab")
                    }
                    self.navigateTo(.fitsViewer)
                    host.startBlink(tabA: host.activeTabIndex, tabB: partner)
                default: return .rejected("Unknown action '\(action)'")
                }
                return .applied(.init(applied: true, isBlinking: host.isBlinking, paused: host.isBlinkPaused))
            }
        })
    }

    func makeSwitchFITSTabTool() -> SwitchFITSTabTool {
        SwitchFITSTabTool(apply: { [weak self] index in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.tabs.indices.contains(index) else { return "index \(index) out of range 0…\(max(0, host.tabs.count - 1))" }
                self.navigateTo(.fitsViewer)
                host.activeTabIndex = index
                return nil
            }
        })
    }

    func makeSetTabSyncTool() -> SetTabSyncTool {
        let activity = agentsService.activityStore
        return SetTabSyncTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.hasMultipleTabs else {
                    return .rejected("Tab sync needs at least 2 open FITS tabs")
                }
                if let link = args.linkCrosshair {
                    let wasOff = !host.linkedState.linkCrosshair
                    host.linkedState.linkCrosshair = link
                    if link && wasOff {
                        // The UI toggle norths-up unrotated tabs on enable so
                        // linked crosshairs land on consistently oriented views.
                        for tab in host.tabs where tab.viewport.rotation == 0 {
                            tab.applyNorthUp()
                        }
                    }
                }
                if let zoom = args.syncZoom { host.linkedState.linkZoom = zoom }
                activity.append(.live(
                    kind: "set_tab_sync",
                    summary: "Adjusted tab sync (crosshair: \(host.linkedState.linkCrosshair), zoom: \(host.linkedState.linkZoom))",
                    origin: .external(clientID: "set_tab_sync")))
                return .applied(.init(
                    linkCrosshair: host.linkedState.linkCrosshair,
                    syncZoom: host.linkedState.linkZoom,
                    usesImpreciseWCS: host.syncUsesImpreciseWCS))
            }
        })
    }

    func makeSearchAtCrosshairTool() -> SearchAtCrosshairTool {
        let activity = agentsService.activityStore
        return SearchAtCrosshairTool(run: { [weak self] in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab,
                      let ra = tab.crosshairRADeg, let dec = tab.crosshairDecDeg else {
                    return .rejected("No crosshair with sky coordinates — place one with fits_goto_coordinate")
                }
                self.dispatch(.searchCoordinates(ra: ra, dec: dec))
                activity.append(.live(
                    kind: "search_at_crosshair",
                    summary: String(format: "Searching at crosshair (%.4f°, %+0.4f°)", ra, dec),
                    origin: .external(clientID: "search_at_crosshair")))
                return .applied(raDeg: ra, decDeg: dec)
            }
        })
    }
}
