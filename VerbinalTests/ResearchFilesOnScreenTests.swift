// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 44 P7, live (F-7): a file's place was read as "Laptop computer".
/// Plan 46 M3: the Files rows are state — the badge says where each file is
/// and is not a control, and the rows' own Open, Show and Remove are gone:
/// the record's buttons and Move To… act on its files.
@MainActor
final class ResearchFilesOnScreenTests: XCTestCase {
    func testAFilesPlaceIsReadAsStateNotAControl() async throws {
        try await AXReadable.require()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("qa44-p7.fits")
        FileManager.default.createFile(atPath: file.path, contents: Data("SIMPLE".utf8))
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?745234/745234p", collection: "CFHT",
                                           observationID: "745234", targetName: "D2", instrument: "", filter: "", ra: "",
                                           dec: "", startDate: "", calLevel: "", localPath: file.path)
        record.fileSize = 6
        record.storagePath = "Verbinal-Results/research/qa44-p7.fits"
        let state = AppState()

        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 700, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResearchFilesSection(observation: record, model: state.researchModel)
            .padding().frame(width: 700, height: 240).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "research" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(600))
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        let elements = snapshot.elements(in: ref.index)
        let read = elements.map { "\($0.kind):\($0.name ?? "-")" }
        let badge = elements.first { $0.name?.contains("Where qa44-p7.fits is") == true }
        XCTAssertEqual(badge?.name, "Where qa44-p7.fits is: On this Mac and in your storage", "\(read)")
        XCTAssertEqual(badge?.kind, .image, "where it is, not a menu: \(read)")
        for gone in ["Open qa44-p7.fits", "Show qa44-p7.fits in Finder", "Remove qa44-p7.fits"] {
            XCTAssertFalse(elements.contains { $0.name == gone }, "\(gone): the record's buttons do it")
        }
    }
}
