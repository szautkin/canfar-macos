// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// DRY guard: sexagesimal is written in exactly one place,
/// `VerbinalKit/Coordinates/Sexagesimal.swift`. Two private copies once
/// disagreed — one printed `23h59m60.00s` — so a third must not appear.
final class SexagesimalGuardTests: XCTestCase {

    /// Format strings that spell an h/m/s or d/m/s layout by hand.
    private let handRolled = [
        #"%02dh%02dm"#, #"%02d:%02d:%02d"#, #"%02d\u{00b0}"#, #"%02d\u{00B0}"#, "%02d°", #"%02d:%02d:""#,
    ]

    func testNoFileOutsideSexagesimalFormatsSexagesimal() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["Verbinal", "shared/VerbinalKit/Sources"].map { repo.appendingPathComponent($0) }
        var offenders: [String] = []
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift", url.lastPathComponent != "Sexagesimal.swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                if handRolled.contains(where: text.contains) {
                    offenders.append(url.path.replacingOccurrences(of: repo.path + "/", with: ""))
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "format sexagesimal with Sexagesimal.formatHMS/formatDMS: \(offenders)")
    }
}
