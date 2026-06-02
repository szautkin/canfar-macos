// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Guard for the Headless tab's progress presentation contract,
/// added alongside ticket 055 (removal of the dead
/// `showHeadlessLaunchProgress` @State in `LaunchFormView`).
///
/// The Standard/Advanced launch flows present a `LaunchProgressSheet`
/// driven by the view's private `showLaunchProgress` binding. The
/// Headless flow is deliberately different: it renders progress and
/// feedback *inline* from `HeadlessLaunchModel`'s observable status
/// fields (`launchStatus`, `launchSuccess`, `lastLaunchedJobIDs`,
/// `hasError`/`errorMessage`) — there is no headless progress-sheet
/// binding. The dead `showHeadlessLaunchProgress` flag falsely
/// implied one existed.
///
/// These tests pin that the model exposes everything the inline
/// surface needs, so a reviewer who sees the missing flag understands
/// it was never load-bearing and isn't tempted to reintroduce it.
@MainActor
final class HeadlessLaunchProgressInlineTests: XCTestCase {

    private func makeModel() -> HeadlessLaunchModel {
        let service = HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession()))
        return HeadlessLaunchModel(headlessService: service, recentLaunchStore: RecentLaunchStore())
    }

    /// A successful headless launch surfaces its progress/feedback
    /// purely through the model's inline status fields — no external
    /// progress-sheet binding is consulted or required.
    func testSuccessfulLaunchSurfacesInlineStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://ws-uv.canfar.net/skaha/v1/session")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("headless-job-1\n".utf8))
        }

        let model = makeModel()
        model.sessionName = "smoke"
        model.cmd = "echo hi"
        model.selectedImage = ParsedImage(
            id: "images.canfar.net/skaha/terminal:1.1.2",
            registry: "images.canfar.net",
            project: "skaha",
            name: "terminal",
            version: "1.1.2",
            label: "terminal:1.1.2",
            types: ["headless"]
        )

        await model.launch()

        XCTAssertTrue(model.launchSuccess, "inline success flag must drive the feedback label")
        XCTAssertEqual(model.lastLaunchedJobIDs, ["headless-job-1"],
                       "inline job ids must drive the success label")
        XCTAssertFalse(model.launchStatus.isEmpty, "inline status text must be populated")
        XCTAssertFalse(model.hasError)
    }

    /// A failed headless launch likewise reports inline via
    /// `hasError`/`errorMessage` — the Headless tab never gates
    /// feedback on a progress-sheet flag.
    func testValidationFailureSurfacesInlineError() async {
        let model = makeModel()
        // Missing image + cmd → validation fails before any request.
        model.sessionName = "smoke"

        await model.launch()

        XCTAssertTrue(model.hasError, "inline error flag must drive the error label")
        XCTAssertFalse(model.errorMessage.isEmpty, "inline error message must be populated")
        XCTAssertFalse(model.launchSuccess)
    }
}
