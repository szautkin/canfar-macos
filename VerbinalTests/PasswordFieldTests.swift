// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// The login's password field shows and hides what was typed: hidden, it is
/// a secure field; shown, the same text in plain view.
@MainActor
final class PasswordFieldTests: XCTestCase {

    private struct Host: View {
        @State var password = "s3cret"
        @FocusState var focus: Int?
        let revealed: Bool
        var body: some View {
            PasswordField("Password", text: $password, focus: $focus, field: 1, revealed: revealed)
                .frame(width: 260)
        }
    }

    /// The editable text fields AppKit draws for the field, hosted in a window.
    private func fields(revealed: Bool) async throws -> [NSTextField] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(revealed: revealed))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        func all(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap(all)
        }
        return all(try XCTUnwrap(window.contentView)).filter(\.isEditable)
    }

    func testHiddenItIsASecureField() async throws {
        let shown = try await fields(revealed: false)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first is NSSecureTextField, "\(shown)")
        XCTAssertEqual(shown.first?.stringValue, "s3cret")
    }

    func testShownItIsThePlainText() async throws {
        let shown = try await fields(revealed: true)
        XCTAssertEqual(shown.count, 1)
        XCTAssertFalse(shown.first is NSSecureTextField, "\(shown)")
        XCTAssertEqual(shown.first?.stringValue, "s3cret")
    }
}
