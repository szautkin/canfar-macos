// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 30 T: every sheet, popover, confirmation and alert is known while it
/// is shown, so an assistant can close it by its name; those that need
/// nothing chosen first open by their name.
@MainActor
final class PresentationsTests: XCTestCase {

    /// The guardrail: a presentation without its `.uiPresented` could not be
    /// closed by an assistant — "anything in the app", the person said.
    func testEveryPresentationIsRegistered() throws {
        let presenting = try NSRegularExpression(pattern: #"^\s*\.(sheet|popover|confirmationDialog|alert)\("#, options: .anchorsMatchLines)
        let registering = try NSRegularExpression(pattern: #"^\s*\.uiPresented\("#, options: .anchorsMatchLines)
        // A system file panel runs through UIPresentations' own runModal (plan 30 T2).
        let panels = try NSRegularExpression(pattern: #"\.runModal\(\)"#)
        var missing: [String] = []
        for (file, text) in try appSources() where file.lastPathComponent != "UIPresentations.swift" {
            let range = NSRange(text.startIndex..., in: text)
            let shown = presenting.numberOfMatches(in: text, range: range)
            let named = registering.numberOfMatches(in: text, range: range)
            if shown > named { missing.append("\(file.lastPathComponent): \(shown) presented, \(named) registered") }
            if panels.numberOfMatches(in: text, range: range) > 0 {
                missing.append("\(file.lastPathComponent): a panel run on its own, not through UIPresentations.runModal")
            }
        }
        XCTAssertTrue(missing.isEmpty, "\n" + missing.joined(separator: "\n"))
    }

    /// Plan 30 T2: every sheet, popover and file panel an assistant cannot
    /// open by its name has a control marked as what opens it — or a reason
    /// it has none, which stays true.
    func testEverySheetPopoverAndPanelHasAWayToOpen() throws {
        let texts = try appSources().map(\.text)
        let all = texts.joined(separator: "\n")
        let named = try NSRegularExpression(pattern: #"\.uiPresented\("([^"]+)", \.(?:sheet|popover)|runModal\(panel, "([^"]+)"\)"#)
        let names = Set(named.matches(in: all, range: NSRange(all.startIndex..., in: all)).compactMap { match in
            [1, 2].lazy.compactMap { Range(match.range(at: $0), in: all).map { String(all[$0]) } }.first
        })
        XCTAssertGreaterThan(names.count, 30, "the presentations are found")
        AppState().registerOpenablePresentations()
        let byName = Set(UIPresentations.shared.openable.map(\.name))
        let exempt: [String: String] = [
            "Observation Detail": "a result's row opens it; so does open_observation_detail",
            "Open As": "the app asks, when a file opens as an image or as a cube",
            "Preview": "shows while the pointer is over a thumbnail",
            "Job Events and Logs": "from a job's right-click menu; get_headless_job_logs and _events read the same",
            "Launch Progress": "follows a launch",
            "Relaunch Progress": "follows a relaunch",
            "Session Action": "follows a session's action",
            "Save Observation": "follows a download; download_observation saves without it",
            "Re-grant Access": "the app asks, when a saved file must be allowed again",
            "Save Figure": "a choice in an export sheet's Save menu, the person's; export_fits_figure and export_cube_figure write figures",
            "Save Results": "a choice in the Export menu, the person's; export_search_results writes them",
            "Export Session Logs": "a choice in the Export menu, the person's; export_session_log writes them",
            "Export Marks": "from a mark's right-click menu",
        ]
        let missing = names.filter { name in
            !byName.contains(name) && exempt[name] == nil
                && !all.contains(".opens(\"\(name)\")") && !all.contains("opens: \"\(name)\")")
        }
        XCTAssertEqual(missing.sorted(), [], "mark the control that opens each with .opens(name)")
        XCTAssertEqual(Set(exempt.keys).subtracting(names).sorted(), [], "an exemption names one that is there")
    }

    /// The app's own sources, iOS's own views aside.
    private func appSources() throws -> [(file: URL, text: String)] {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verbinal")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/Views/iOS/") } ?? []
        XCTAssertGreaterThan(files.count, 100, "the app's sources are found")
        return try files.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testAShownOneIsClosedByItsNameOrAsTheFrontOne() {
        let presentations = UIPresentations()
        var open = (first: true, second: true)
        let first = presentations.begin("Batch Jobs", .sheet) { open.first = false }
        _ = presentations.begin("Stop and Delete the Job?", .confirmation) { open.second = false }
        XCTAssertEqual(presentations.shown(named: "front")?.name, "Stop and Delete the Job?")
        XCTAssertEqual(presentations.shown(named: "batch jobs")?.kind, .sheet, "any case")
        XCTAssertEqual(presentations.shown(named: "Stop and")?.kind, .confirmation, "what it begins with")
        XCTAssertTrue(presentations.close(presentations.shown(named: "Batch Jobs")!))
        XCTAssertFalse(open.first)
        XCTAssertTrue(open.second, "only that one")
        presentations.end(first)
        XCTAssertEqual(presentations.shown.map(\.name), ["Stop and Delete the Job?"])
        XCTAssertNil(presentations.shown(named: "nothing like it"))
    }

    /// A sheet, shown, is listed by its name; closed through the registry, its
    /// own binding is cleared, and it is gone from the list.
    func testASheetRegistersWhileShown() async throws {
        final class Flag: ObservableObject { @Published var on = false }
        struct Host: View {
            @ObservedObject var flag: Flag
            var body: some View {
                Color.clear.frame(width: 300, height: 200)
                    .uiPresented("Test Sheet", .sheet, isPresented: $flag.on)
                    .sheet(isPresented: $flag.on) { Text("Inside").padding() }
            }
        }
        let flag = Flag()
        let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(flag: flag))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(UIPresentations.shared.shown(named: "Test Sheet"))
        flag.on = true
        try await Task.sleep(for: .milliseconds(400))
        let shown = try XCTUnwrap(UIPresentations.shared.shown(named: "Test Sheet"))
        UIPresentations.shared.close(shown)
        XCTAssertFalse(flag.on, "closed as the person's Esc would")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(UIPresentations.shared.shown(named: "Test Sheet"))
    }

    final class Seen: @unchecked Sendable { var shown: String? }

    /// A system file panel is known while it is up and closes as its Cancel
    /// would — and, run from async code, the tools still answer meanwhile
    /// (plan 30 T2).
    func testAFilePanelIsKnownAndClosedAsCancel() async throws {
        let seen = Seen()
        let closing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            let shown = UIPresentations.shared.shown(named: "Test Save")
            seen.shown = shown.map { "\($0.name) \($0.kind.rawValue)" }
            if let shown { UIPresentations.shared.close(shown) }
        }
        // Were the main actor held, nothing would close it: this does, and the test fails.
        let rescue = Timer(timeInterval: 8, repeats: false) { _ in MainActor.assumeIsolated { NSApp.abortModal() } }
        RunLoop.main.add(rescue, forMode: .common)
        defer { rescue.invalidate() }
        let response = await UIPresentations.shared.runModal(NSSavePanel(), "Test Save")
        await closing.value
        XCTAssertEqual(seen.shown, "Test Save filePanel", "listed while up, and the main actor free")
        XCTAssertEqual(response, .cancel)
        XCTAssertNil(UIPresentations.shared.shown(named: "Test Save"))
    }

    /// open_ui presses the control that opens a sheet — by the sheet's name
    /// — and close_ui closes it (plan 30 T2).
    func testOpenUIPressesWhatOpensASheet() async throws {
        try await AXReadable.require()
        struct Openers: View {
            @State private var notes = false
            var body: some View {
                VStack(spacing: 20) {
                    Button("Notes…") { notes = true }.opens("Test Notes")
                }
                .frame(width: 400, height: 300)
                .uiWindowPlace(.main)
                .uiPresented("Test Notes", .sheet, isPresented: $notes)
                .sheet(isPresented: $notes) { Text("Inside the notes").padding().frame(width: 220, height: 120) }
            }
        }
        let state = AppState()
        let window = NSWindow(contentRect: NSRect(x: 280, y: 280, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Openers())
        window.orderFrontRegardless()
        defer { window.close() }
        await state.uiHintPresenter.ready()
        try await Task.sleep(for: .milliseconds(400))
        let opener = try XCTUnwrap(state.uiHintPresenter.snapshot().elements.first { $0.presents == "Test Notes" })
        XCTAssertTrue(opener.closed)

        let opened = await state.setUIOpen(.init(target: "Test Notes"), open: true)
        XCTAssertTrue(opened.done, "\(opened)")
        XCTAssertEqual(opened.id, "presented:Test Notes")
        XCTAssertNotNil(UIPresentations.shared.shown(named: "Test Notes"))
        let again = await state.setUIOpen(.init(target: "Test Notes"), open: true)
        XCTAssertEqual(again.message, "Test Notes was already open")
        let closed = await state.setUIOpen(.init(target: "Test Notes"), open: false)
        XCTAssertTrue(closed.done)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(UIPresentations.shared.shown(named: "Test Notes"))
    }

    func testTheToolsOpenAndCloseByName() async {
        // A window shows, as the person's would: nothing opens in sight without one.
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let state = AppState()
        state.registerOpenablePresentations()
        let opened = await state.setUIOpen(.init(target: "About Verbinal"), open: true)
        XCTAssertTrue(opened.done)
        XCTAssertEqual(state.activeSheet, .about)
        XCTAssertTrue(UIPresentations.shared.openable.map(\.name).contains("Batch Jobs"))
    }
}
