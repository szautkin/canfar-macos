// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for the Windows-parity tool batch (renew_session,
/// platform/quota reads, search export/load, file upload, research
/// bundle, FITS/Cube viewer control, tabs). Stub closures — no network,
/// no viewer models.
final class ParityToolsTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func decodeJSON(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let data) = result else {
            XCTFail("expected .data, got \(result)")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - renew_session

    func testRenewSessionPlanCarriesTrimmedID() async throws {
        let tool = RenewSessionTool()
        let plan = try await tool.plan(.init(id: "  abc123  "), context: ctx())
        XCTAssertEqual(plan.kind, "renew_session")
        let payload = try JSONDecoder().decode(RenewSessionTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.id, "abc123")
    }

    func testRenewSessionPlanRejectsEmptyID() async {
        let tool = RenewSessionTool()
        do {
            _ = try await tool.plan(.init(id: "   "), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    @MainActor
    func testRenewSessionApplierForwardsID() async throws {
        let box = Box()
        let applier = RenewSessionApplier(
            renew: { id in await box.set(id) },
            activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let plan = try await RenewSessionTool().plan(.init(id: "s42"), context: ctx())
        let proposal = PendingProposal(
            toolName: "renew_session", kind: plan.kind, summary: plan.summary,
            payload: plan.payload, origin: .external(clientID: "test"), requestID: UUID())
        try await applier.apply(proposal)
        let got = await box.value
        XCTAssertEqual(got, "s42")
    }

    // MARK: - platform load / storage quota

    func testGetPlatformLoadReturnsFetchedStats() async throws {
        let tool = GetPlatformLoadTool(fetch: {
            .init(instances: .init(session: 2, desktopApp: 1, headless: 3, total: 6),
                  cores: .init(requested: 10, available: 90),
                  ram: .init(requestedGB: 16, availableGB: 240))
        })
        let result = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        let json = try decodeJSON(result)
        let cores = try XCTUnwrap(json["cores"] as? [String: Any])
        XCTAssertEqual(cores["available"] as? Double, 90)
    }

    func testGetStorageQuotaAuthRequiredSurfacesTyped() async {
        let tool = GetStorageQuotaTool(fetch: { throw ToolFailureReason.authRequired })
        let result = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed(let reason) = result, case .authRequired = reason else {
            return XCTFail("expected .failed(.authRequired), got \(result)")
        }
    }

    // MARK: - export_search_results

    func testExportSearchResultsPlanRejectsBadFormat() async {
        let tool = ExportSearchResultsTool()
        do {
            _ = try await tool.plan(.init(format: "xlsx", adql: nil, maxRecords: nil), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testExportSearchResultsPlanAcceptsVotable() async throws {
        let plan = try await ExportSearchResultsTool()
            .plan(.init(format: "votable", adql: "SELECT TOP 1 * FROM caom2.Plane", maxRecords: 50), context: ctx())
        XCTAssertEqual(plan.kind, "export_search_results")
        let payload = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.maxRecords, 50)
    }

    func testExportSearchResultsPlanAllowsOmittingAdql() async throws {
        let plan = try await ExportSearchResultsTool()
            .plan(.init(format: "csv", adql: nil, maxRecords: 10), context: ctx())
        let payload = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: plan.payload)
        XCTAssertNil(payload.adql)
        XCTAssertEqual(payload.format, "csv")
    }

    func testSaveQueryPlanEmitsStableId() async throws {
        let plan = try await SaveQueryTool().plan(
            .init(name: "M31 cone", adql: "SELECT 1", description: nil, tags: nil),
            context: ctx())
        let payload = try JSONDecoder().decode(SaveQueryTool.Payload.self, from: plan.payload)
        XCTAssertNotNil(UUID(uuidString: payload.id))
        XCTAssertEqual(payload.name, "M31 cone")
    }

    func testRequestFolderAccessExternalReturnsDeniedWithoutCallingPicker() async throws {
        final class Spy: @unchecked Sendable {
            var called = false
        }
        let spy = Spy()
        let tool = RequestFolderAccessTool(request: { _ in
            spy.called = true
            return .granted("/tmp")
        })
        let result = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        XCTAssertFalse(spy.called, "MCP clients must not present NSOpenPanel")
        let json = try decodeJSON(result)
        XCTAssertEqual(json["granted"] as? Bool, false)
        XCTAssertNotNil(json["note"] as? String)
    }

    // MARK: - load_saved_search

    func testLoadSavedSearchRequiresExactlyOneTarget() async {
        let tool = LoadSavedSearchTool(apply: { _, _ in nil })
        let both = await tool.invoke(
            arguments: argsData(["savedQueryID": "a", "recentSearchID": "b"]), context: ctx())
        guard case .failed = both else { return XCTFail("expected .failed for both ids") }
        let neither = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = neither else { return XCTFail("expected .failed for no ids") }
    }

    func testLoadSavedSearchAppliesSingleTarget() async throws {
        let tool = LoadSavedSearchTool(apply: { saved, recent in
            XCTAssertEqual(saved, "q1"); XCTAssertNil(recent); return nil
        })
        let result = await tool.invoke(arguments: argsData(["savedQueryID": "q1"]), context: ctx())
        let json = try decodeJSON(result)
        XCTAssertEqual(json["applied"] as? Bool, true)
    }

    // MARK: - upload_file_to_vospace

    func testUploadFilePlanRejectsMissingFileAndTraversal() async {
        let tool = UploadFileToVOSpaceTool()
        do {
            _ = try await tool.plan(.init(localPath: "/nonexistent/x.fits", remotePath: "a/b"), context: ctx())
            XCTFail("expected failure for missing file")
        } catch { /* expected */ }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("parity-up-\(UUID().uuidString).bin")
        try? Data([1, 2, 3]).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            _ = try await tool.plan(.init(localPath: temp.path, remotePath: "../escape"), context: ctx())
            XCTFail("expected failure for path traversal")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testUploadFilePlanAcceptsRealFile() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("parity-up-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 128).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let plan = try await UploadFileToVOSpaceTool()
            .plan(.init(localPath: temp.path, remotePath: "exports/x.bin"), context: ctx())
        let payload = try JSONDecoder().decode(UploadFileToVOSpaceTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.remotePath, "exports/x.bin")
    }

    @MainActor
    func testUploadFileApplierReturnsWithoutWaitingForPUT() async throws {
        let applier = UploadFileToVOSpaceApplier(
            upload: { _, _ in try await Task.sleep(for: .seconds(2)) },
            activity: AgentActivityStore(fileName: "test-activity-upload-\(UUID().uuidString).json"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("parity-up-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let plan = try await UploadFileToVOSpaceTool()
            .plan(.init(localPath: temp.path, remotePath: "exports/x.bin"), context: ctx())
        let proposal = PendingProposal(
            toolName: "upload_file_to_vospace", kind: plan.kind, summary: plan.summary,
            payload: plan.payload, origin: .external(clientID: "test"), requestID: UUID())
        let started = ContinuousClock.now
        let extra = try await applier.applyReturningResult(proposal)
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, Duration.milliseconds(500),
                          "MCP must not wait on the PUT; elapsed \(elapsed)")
        let ack = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: extra)
        XCTAssertEqual(ack.id, "exports/x.bin")
        XCTAssertTrue(ack.note?.contains("list_vospace_path") == true)
        try await Task.sleep(for: .seconds(2.2))
    }

    func testStageCopyForUploadPreservesBytesAndRejectsEmpty() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-stage-\(UUID().uuidString).png")
        let payload = Data(repeating: 0x89, count: 128)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try UploadFileToVOSpaceTool.stageCopyForUpload(source)
        defer { try? FileManager.default.removeItem(at: staged) }
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        XCTAssertNotEqual(staged.path, source.path)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-stage-empty-\(UUID().uuidString).bin")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try UploadFileToVOSpaceTool.stageCopyForUpload(empty))
    }

    // MARK: - export_research_bundle

    func testExportResearchBundlePayloadDefaultsToFalse() async throws {
        let plan = try await ExportResearchBundleTool()
            .plan(.init(includeFileCopies: nil, uploadToVOSpace: nil), context: ctx())
        let payload = try JSONDecoder().decode(ExportResearchBundleTool.Payload.self, from: plan.payload)
        XCTAssertFalse(payload.includeFileCopies)
        XCTAssertFalse(payload.uploadToVOSpace)
    }

    // MARK: - FITS viewer control

    func testSetFITSViewForwardsAndReportsErrors() async throws {
        let ok = SetFITSViewTool(apply: { args in
            XCTAssertEqual(args.stretch, "log"); return nil
        })
        let good = await ok.invoke(arguments: argsData(["stretch": "log"]), context: ctx())
        let json = try decodeJSON(good)
        XCTAssertEqual(json["applied"] as? Bool, true)

        let failing = SetFITSViewTool(apply: { _ in "No FITS file is open in the viewer" })
        let bad = await failing.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed(let reason) = bad, case .invalidArgument(let msg) = reason else {
            return XCTFail("expected invalidArgument, got \(bad)")
        }
        XCTAssertTrue(msg.contains("No FITS file"))
    }

    func testSaveFITSBookmarkPlanValidatesRanges() async {
        let tool = SaveFITSBookmarkTool()
        for (label, ra, dec) in [("", 10.0, 10.0), ("x", 400.0, 10.0), ("x", 10.0, 95.0)] {
            do {
                _ = try await tool.plan(.init(label: label, raDeg: ra, decDeg: dec), context: ctx())
                XCTFail("expected invalidArgument for (\(label), \(ra), \(dec))")
            } catch let f as ToolFailureReason {
                guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
            } catch { XCTFail("unexpected: \(error)") }
        }
    }

    func testFITSGotoDistinguishesNoViewerFromOffImage() async throws {
        let noViewer = FITSGotoCoordinateTool(goTo: { _, _ in nil })
        let failed = await noViewer.invoke(
            arguments: argsData(["raDeg": 10.0, "decDeg": 20.0]), context: ctx())
        guard case .failed(let reason) = failed, case .targetNotResolved = reason else {
            return XCTFail("expected targetNotResolved, got \(failed)")
        }

        let offImage = FITSGotoCoordinateTool(goTo: { _, _ in
            .offImage(x: -320, y: 40, whereItFalls: "320 px left of the image")
        })
        let json = try decodeJSON(await offImage.invoke(
            arguments: argsData(["raDeg": 10.0, "decDeg": 20.0]), context: ctx()))
        XCTAssertEqual(json["onImage"] as? Bool, false)
        XCTAssertEqual(json["pixelX"] as? Double, -320)
        XCTAssertTrue((json["message"] as? String ?? "").contains("320 px left of the image"))
    }

    // MARK: - Cube viewer control

    func testGetCubeViewReturnsSnapshot() async throws {
        let tool = GetCubeViewTool(snapshot: {
            .init(isOpen: true, fileName: "m33.fits", nx: 100, ny: 100, nz: 300,
                  channel: 42, viewMode: "slice", colormap: "inferno", stretch: "asinh",
                  windowLo: 0.1, windowHi: 0.9, density: 1.0,
                  maxIntensityProjection: false, autoOrbit: false, isPlaying: false,
                  background: "dark", spectralScale: 1.5, quality: 384,
                  showSlicePlane: true, playbackFPS: 12,
                  opacityCurve: [[0, 0], [1, 1]],
                  camera: .init(azimuthDeg: 40.1, elevationDeg: 28.6, distance: 2.6))
        })
        let json = try decodeJSON(await tool.invoke(arguments: Data("{}".utf8), context: ctx()))
        XCTAssertEqual(json["channel"] as? Int, 42)
        XCTAssertEqual(json["viewMode"] as? String, "slice")
        let camera = try XCTUnwrap(json["camera"] as? [String: Any])
        XCTAssertEqual(camera["distance"] as? Double, 2.6)
    }

    func testProbeCubeSpectrumForwardsTypedFailure() async {
        let tool = ProbeCubeSpectrumTool(probe: { _ in
            throw ToolFailureReason.targetNotResolved("No cube is open in the Cube Viewer")
        })
        let result = await tool.invoke(arguments: argsData(["x": 1, "y": 2]), context: ctx())
        guard case .failed(let reason) = result, case .targetNotResolved = reason else {
            return XCTFail("expected targetNotResolved, got \(result)")
        }
    }

    // MARK: - set_cube_camera

    func testSetCubeCameraEchoesFinalPoseAndMapsRejection() async throws {
        let ok = SetCubeCameraTool(apply: { args in
            XCTAssertEqual(args.orbitByAzimuthDeg, 90)
            XCTAssertEqual(args.reveal, true)
            return .applied(.init(azimuthDeg: 130.1, elevationDeg: 28.6, distance: 2.6))
        })
        let json = try decodeJSON(await ok.invoke(
            arguments: argsData(["orbitByAzimuthDeg": 90, "reveal": true]), context: ctx()))
        let camera = try XCTUnwrap(json["camera"] as? [String: Any])
        XCTAssertEqual(camera["azimuthDeg"] as? Double, 130.1)

        let closed = SetCubeCameraTool(apply: { _ in .rejected("No cube is open in the Cube Viewer") })
        let result = await closed.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed(let reason) = result, case .invalidArgument = reason else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
    }

    // MARK: - opacity curve validation

    func testOpacityCurveValidation() {
        XCTAssertNil(SetCubeViewTool.validateOpacityCurve([[0, 0], [0.5, 0.2], [1, 1]]))
        XCTAssertNotNil(SetCubeViewTool.validateOpacityCurve([[0, 0]]), "too few points")
        XCTAssertNotNil(SetCubeViewTool.validateOpacityCurve([[0, 0], [0.5]]), "malformed pair")
        XCTAssertNotNil(SetCubeViewTool.validateOpacityCurve([[0, 0], [1.2, 1]]), "out of range")
        XCTAssertNotNil(SetCubeViewTool.validateOpacityCurve([[0.6, 0], [0.4, 1]]), "unsorted")
        XCTAssertNotNil(
            SetCubeViewTool.validateOpacityCurve(Array(repeating: [0.5, 0.5], count: 17)),
            "too many points")
    }

    // MARK: - Open as… sheet

    func testChooseViewerAppliesCube() async throws {
        let tool = ChooseViewerTool(choose: { viewer in
            XCTAssertEqual(viewer, "cube")
            return .init(applied: true, viewer: "cube", path: "/tmp/c.fits",
                         note: "Opened in the 3D Cube Viewer.")
        })
        let result = await tool.invoke(arguments: argsData(["viewer": "CUBE"]), context: ctx())
        let json = try decodeJSON(result)
        XCTAssertEqual(json["applied"] as? Bool, true)
        XCTAssertEqual(json["viewer"] as? String, "cube")
        XCTAssertEqual(json["path"] as? String, "/tmp/c.fits")
    }

    func testChooseViewerRejectsUnknownViewer() async {
        let tool = ChooseViewerTool(choose: { _ in
            XCTFail("should not choose")
            return .init(applied: true, viewer: "fits", path: nil, note: "")
        })
        let result = await tool.invoke(arguments: argsData(["viewer": "carta"]), context: ctx())
        guard case .failed(let reason) = result, case .invalidArgument = reason else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
    }

    func testChooseViewerSurfacesNoSheetError() async {
        let tool = ChooseViewerTool(choose: { _ in
            throw ToolFailureReason.invalidArgument("No Open as… sheet is showing")
        })
        let result = await tool.invoke(arguments: argsData(["viewer": "fits"]), context: ctx())
        guard case .failed(let reason) = result, case .invalidArgument(let msg) = reason else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
        XCTAssertTrue(msg.contains("Open as"))
    }

    func testOpenLocalFileRejectsBadViewer() async {
        let tool = OpenLocalFileTool(open: { _, _ in
            XCTFail("should not open")
            return .init(applied: true, path: "/tmp/a.fits", viewer: nil,
                         pendingViewerChoice: false, note: nil)
        })
        let result = await tool.invoke(
            arguments: argsData(["path": "/tmp/a.fits", "viewer": "carta"]), context: ctx())
        guard case .failed(let reason) = result, case .invalidArgument = reason else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
    }

    func testOpenLocalFileReturnsPendingViewerChoice() async throws {
        let tool = OpenLocalFileTool(open: { path, viewer in
            XCTAssertEqual(path, "/tmp/cube.fits")
            XCTAssertNil(viewer)
            return .init(applied: true, path: path, viewer: nil,
                         pendingViewerChoice: true,
                         note: AppState.viewerChoiceAgentNote(filename: "cube.fits"))
        })
        let result = await tool.invoke(
            arguments: argsData(["path": "/tmp/cube.fits"]), context: ctx())
        let json = try decodeJSON(result)
        XCTAssertEqual(json["pendingViewerChoice"] as? Bool, true)
        XCTAssertTrue((json["note"] as? String)?.contains("choose_viewer") == true)
    }

    func testGetCurrentViewEncodesPendingViewerChoice() throws {
        let out = GetCurrentViewTool.Output(
            mode: "landing", modeTitle: "Landing",
            isAuthenticated: false, username: "",
            searchFocusRA: nil, searchFocusDec: nil,
            searchTab: nil,
            searchResultsTotal: nil,
            searchResultsFiltered: nil,
            openFITSPaths: [],
            pendingViewerChoice: .init(
                path: "/tmp/cube.fits", filename: "cube.fits",
                note: AppState.viewerChoiceAgentNote(filename: "cube.fits")),
            pendingProposalsCount: 0,
            agentsEnabled: true,
            autoApplyEnabled: true,
            followAgentActivityEnabled: true)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(out)) as? [String: Any])
        let pending = try XCTUnwrap(json["pendingViewerChoice"] as? [String: Any])
        XCTAssertEqual(pending["filename"] as? String, "cube.fits")
        XCTAssertTrue((pending["note"] as? String)?.contains("choose_viewer") == true)
    }

    // MARK: - tabs

    func testCloseTabReportsClosureError() async {
        let tool = ViewerTabActions.closeTab { _ in "No tabs are open" }
        let result = await tool.invoke(arguments: argsData(["kind": "fits"]), context: ctx())
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
    }

    func testCloseTabPassesKindAndIndex() async throws {
        let seen = Locked<(String, Int?)?>(nil)
        let tool = ViewerTabActions.closeTab { args in seen.set((args.kind, args.index)); return nil }
        let result = await tool.invoke(arguments: argsData(["kind": "cube", "index": 2]), context: ctx())
        guard case .data = result else { return XCTFail("expected data, got \(result)") }
        XCTAssertEqual(seen.value?.0, "cube")
        XCTAssertEqual(seen.value?.1, 2)
    }

    // MARK: - get_proposal_state

    func testGetProposalStateAcceptsProposalIdAlias() async throws {
        let store = InMemoryProposalStore()
        let proposal = await store.enqueue(PendingProposal(
            toolName: "t", kind: "k", summary: "s",
            payload: Data("{}".utf8), origin: .user
        ))
        let tool = GetProposalStateTool()
        let result = await tool.invoke(
            arguments: argsData(["proposalId": proposal.id.uuidString]),
            context: AIToolContext(origin: .external(clientID: "test"),
                                   proposals: store, budget: ProposalBudget(limit: 9))
        )
        let json = try decodeJSON(result)
        XCTAssertEqual(json["state"] as? String, "pending")
        XCTAssertEqual(json["id"] as? String, proposal.id.uuidString)
    }

    func testGetProposalStateRequiresAnId() async {
        let tool = GetProposalStateTool()
        let result = await tool.invoke(arguments: argsData([:]), context: ctx())
        guard case .failed(.invalidArgument) = result else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
    }

    // MARK: - helpers

    private actor Box {
        private(set) var value: String?
        func set(_ v: String) { value = v }
    }
}
