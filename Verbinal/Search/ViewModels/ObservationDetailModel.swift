// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// View model for ``ObservationDetailViewer``.
///
/// Implements progressive enhancement:
///  • the row data (`SearchResult` + `SearchResultColumns`) is available
///    instantly and feeds the Overview/Raw tabs immediately,
///  • the CAOM2 detail document is fetched in the background and, once it
///    arrives, enriches Coverage/Files/Provenance with full hierarchy data.
/// Auth-gated collections (NEOSSAT, …) surface a polite "Sign in to CADC"
/// notice instead of a blank panel.
@Observable
@MainActor
final class ObservationDetailModel {
    let result: SearchResult
    let columns: SearchResultColumns
    private let caom2Service: CAOM2Service
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ObservationDetail")

    /// The CAOM-2 record (plan 38): loading, loaded, or why not — sign-in
    /// required and not found are problems trying again does not help.
    var load: Phase<CAOM2Observation> = .idle
    var caom2: CAOM2Observation? { load.value }

    /// Whether `loadCAOM2()` may (re)start: never started, or a failure
    /// trying again can help.
    var mayLoad: Bool {
        switch load {
        case .idle: true
        case .failed(let problem, _): problem.retry
        case .working, .ready: false
        }
    }

    init(
        result: SearchResult,
        columns: SearchResultColumns,
        caom2Service: CAOM2Service = CAOM2Service()
    ) {
        self.result = result
        self.columns = columns
        self.caom2Service = caom2Service
    }

    /// Convenience accessor for the publisher ID stored on the row.
    var publisherID: String { columns.value(in: result, forID: "publisherid") }
    var collection: String  { columns.value(in: result, forID: "collection") }
    var observationID: String { columns.value(in: result, forID: "obsid") }
    var targetName: String  { columns.value(in: result, forID: "targetname") }

    /// Trigger the CAOM2 fetch. Idempotent — successive calls during a load
    /// are no-ops; calls after a successful load just return.
    func loadCAOM2() async {
        guard mayLoad else { return }
        let attempt = load.begin()

        let publisherID = self.publisherID
        guard !publisherID.isEmpty else {
            load.finish(attempt, with: .failure(Problem(.other, String(localized: "No publisher ID for this row."))))
            return
        }

        do {
            let observation = try await caom2Service.fetch(publisherID: publisherID)
            load.finish(attempt, with: .success(observation))
        } catch CAOM2ServiceError.authenticationRequired {
            Self.logger.info("CAOM2 detail requires sign-in: \(publisherID, privacy: .public)")
            load.finish(attempt, with: .failure(Problem(
                .signInRequired, String(localized: "This observation's full metadata requires CADC sign-in."), retry: false)))
        } catch CAOM2ServiceError.observationNotFound {
            load.finish(attempt, with: .failure(Problem(
                .notFound, String(localized: "Observation metadata not available."), retry: false)))
        } catch {
            Self.logger.error("CAOM2 fetch failed: \(error.localizedDescription, privacy: .public)")
            load.finish(attempt, with: .failure(error))
        }
    }
}
