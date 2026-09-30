// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import XCTest

/// Plan 23's guarantee that no request goes unrecorded: the app sends
/// through `URLSession.recordedData(for:)` / `recordedDownload(for:)` or
/// `NetworkClient`, and a raw `URLSession` send anywhere else fails here.
///
/// It reads the sources, so it lives in the package's tests, which run
/// outside the app's sandbox.
final class RequestRecordingCoverageTests: XCTestCase {

    /// The only files a raw send may sit in: the recorded wrappers
    /// themselves, and `NetworkClient`, whose sends each run inside
    /// `ledger.send`.
    private static let recordedPlaces: Set<String> = ["RequestLedger.swift", "NetworkClient.swift"]

    /// `data(for:)`, `download(for:)`, `upload(for:…)`, `bytes(for:)`,
    /// `data(from:)` …, and the task-making forms — across line breaks.
    static let rawSend = try! NSRegularExpression(
        pattern: #"\.(data|download|upload|bytes)\(\s*(for|from):|\.(dataTask|downloadTask|uploadTask|webSocketTask|streamTask)\(\s*with"#)

    private var repository: URL {
        // …/shared/VerbinalKit/Tests/VerbinalKitTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoRequestIsSentOutsideTheRecordedPlaces() throws {
        let roots = ["Verbinal", "shared/VerbinalKit/Sources"].map { repository.appendingPathComponent($0) }
        var sources = 0
        var unrecorded: [String] = []
        for root in roots {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                sources += 1
                guard !Self.recordedPlaces.contains(file.lastPathComponent) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        // Comments may name the APIs.
                        guard let comment = line.range(of: "//") else { return line }
                        return line[..<comment.lowerBound]
                    }
                    .joined(separator: "\n")
                let range = NSRange(code.startIndex..., in: code)
                for match in Self.rawSend.matches(in: code, range: range) {
                    let line = code[..<Range(match.range, in: code)!.lowerBound].filter { $0 == "\n" }.count + 1
                    unrecorded.append("\(file.path.replacingOccurrences(of: repository.path + "/", with: "")):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(sources, 300, "the sources were not found — did the layout change?")
        XCTAssertTrue(unrecorded.isEmpty, """
            Requests sent outside the request ledger — send with `recordedData(for:)` or \
            `recordedDownload(for:)`, so the session log sees them (plan 23): \(unrecorded)
            """)
    }

    /// The scan finds a send however it is written.
    func testTheScanFindsARawSend() {
        let samples = [
            "let (d, r) = try await session.data(for: request)",
            "try await URLSession.shared.data(from: url)",
            "(data, response) = try await session.upload(\n    for: request,\n    fromFile: file)",
            "let task = session.downloadTask(with: request)",
        ]
        for sample in samples {
            let range = NSRange(sample.startIndex..., in: sample)
            XCTAssertEqual(Self.rawSend.numberOfMatches(in: sample, range: range), 1, sample)
        }
        let recorded = "try await session.recordedData(for: request)"
        XCTAssertEqual(Self.rawSend.numberOfMatches(in: recorded, range: NSRange(recorded.startIndex..., in: recorded)), 0)
    }
}
