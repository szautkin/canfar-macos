// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 27 A: the app reads its own windows through the accessibility API —
/// every control, by what it says, and never what is typed.
@MainActor
final class AXElementSourceTests: XCTestCase {

    private struct Sample: View {
        @State private var on = true
        @State private var typed = "typed-secret-words"
        @State private var open = false
        @State private var code = "print(1)"
        var body: some View {
            VStack(alignment: .leading) {
                Button("Run Search") {}
                Button { } label: { Image(systemName: "trash") }.help("Delete the file")
                Toggle("Auto-apply", isOn: $on)
                HStack { Text("Target"); TextField("", text: $typed) }
                SecureField("Password", text: $typed)
                DisclosureGroup("Advanced", isExpanded: $open) { Button("Inside") {} }
                Button("Tagged") {}.pointable("sample.tagged", label: "Tagged", screen: "sample")
                List { ForEach(0..<40) { Text("Row \($0)") } }.frame(height: 100)
                TextEditor(text: $code)
                    .textEditorName("Code to run", pointable: "sample.code")
                    .frame(height: 60)
            }
            .padding()
            .uiWindowPlace(.main)
            .environment(UIPointerRegistry())
        }
    }

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func show() async throws -> (UISnapshot, [UIElement]) {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 480, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Sample())
        window.makeKeyAndOrderFront(nil)
        self.window = window
        try await Task.sleep(for: .milliseconds(400))
        let source = AXElementSource(screenName: { kind, _, _ in kind == .main ? "sample" : "other" })
        var snapshot = source.snapshot()
        // SwiftUI builds its tree on the first ask; the second read has it all.
        try await Task.sleep(for: .milliseconds(200))
        snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber }, "the window is listed")
        return (snapshot, snapshot.elements(in: ref.index))
    }

    func testEveryControlIsATargetByWhatItSays() async throws {
        let (snapshot, elements) = try await show()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window?.windowNumber })
        XCTAssertEqual(ref.kind, .main)
        XCTAssertEqual(ref.screen, "sample")
        func named(_ name: String) -> UIElement? { elements.first { $0.name == name } }
        XCTAssertEqual(named("Run Search")?.kind, .button)
        XCTAssertEqual(named("Trash")?.help, "Delete the file", "an icon is called by its symbol, with its tooltip")
        XCTAssertEqual(named("Auto-apply")?.kind, .toggle)
        XCTAssertEqual(named("Target")?.kind, .textField, "a field called by the caption before it")
        XCTAssertEqual(named("Password")?.kind, .secureField)
        XCTAssertEqual(named("Advanced")?.closed, true)
        XCTAssertNil(named("Inside"), "nothing behind a closed section")
        XCTAssertEqual(named("Tagged")?.id, "sample.tagged")
        XCTAssertEqual(named("Tagged")?.stable, true)
        XCTAssertEqual(named("Code to run")?.id, "sample.code", "a TextEditor named past SwiftUI, on its text view")
        XCTAssertFalse(elements.contains { $0.name?.contains("typed-secret-words") == true }, "what is typed is never read")
        XCTAssertFalse(elements.contains { $0.kind == .button && $0.name == nil && $0.frame.width <= 16 },
                       "no window widgets")
    }

    func testRowsOutOfSightAreNotListedAndEverythingIsInItsWindow() async throws {
        let (_, elements) = try await show()
        let rows = elements.filter { $0.kind == .row }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThan(rows.count, 10, "100 pt of a 40-row list")
        let bounds = CGRect(origin: .zero, size: window?.frame.size ?? .zero)
        for element in elements {
            XCTAssertTrue(bounds.contains(element.visible.insetBy(dx: 1, dy: 1)), "\(element.id) at \(element.visible)")
        }
    }

    /// The person's own window — where they allow a session — is never read.
    func testTheApprovalWindowIsNeverATarget() async throws {
        let approval = NSWindow(contentRect: NSRect(x: 700, y: 120, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        approval.isReleasedWhenClosed = false
        approval.identifier = NSUserInterfaceItemIdentifier(PointableID.Window.sessionApproval.identifier)
        approval.contentView = NSHostingView(rootView: Button("Allow") {}.padding())
        approval.makeKeyAndOrderFront(nil)
        defer { approval.close() }
        let (snapshot, _) = try await show()
        XCTAssertFalse(snapshot.windows.contains { $0.number == approval.windowNumber })
        XCTAssertFalse(snapshot.elements.contains { $0.name == "Allow" })
    }
}
