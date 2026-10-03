// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verbinal")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "the app's sources are found")
        let presenting = try NSRegularExpression(pattern: #"^\s*\.(sheet|popover|confirmationDialog|alert)\("#, options: .anchorsMatchLines)
        let registering = try NSRegularExpression(pattern: #"^\s*\.uiPresented\("#, options: .anchorsMatchLines)
        var missing: [String] = []
        for file in files where !file.path.contains("/Views/iOS/") && file.lastPathComponent != "UIPresentations.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            let shown = presenting.numberOfMatches(in: text, range: range)
            let named = registering.numberOfMatches(in: text, range: range)
            if shown > named { missing.append("\(file.lastPathComponent): \(shown) presented, \(named) registered") }
        }
        XCTAssertTrue(missing.isEmpty, "\n" + missing.joined(separator: "\n"))
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

    func testTheToolsOpenAndCloseByName() async {
        let state = AppState()
        state.registerOpenablePresentations()
        let opened = await state.setUIOpen(.init(target: "About Verbinal"), open: true)
        XCTAssertTrue(opened.done)
        XCTAssertEqual(state.activeSheet, .about)
        XCTAssertTrue(UIPresentations.shared.openable.map(\.name).contains("Batch Jobs"))
    }
}
