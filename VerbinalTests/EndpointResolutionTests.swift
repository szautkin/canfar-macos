// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Pure precedence + normalization tests for the Endpoints settings
/// model: user override > cached registry resolution > CANFAR default.
final class EndpointResolutionTests: XCTestCase {

    private func resolved(_ values: [EndpointField: String]) -> ResolvedEndpoints {
        ResolvedEndpoints(
            values: values,
            fetchedAt: Date(),
            registryBaseURL: APIEndpoints().registryBaseURL
        )
    }

    // MARK: - Precedence

    func testDefaultsWinWhenNothingElseIsSet() {
        let effective = EndpointResolution.effective(overrides: EndpointOverrides(), resolved: nil)
        XCTAssertEqual(effective, APIEndpoints(), "No overrides + no cache must be byte-identical to defaults")
    }

    func testResolvedBeatsDefault() {
        let cache = resolved([.skahaBaseURL: "https://ws-sf.canfar.net/skaha"])
        let effective = EndpointResolution.effective(overrides: EndpointOverrides(), resolved: cache)
        XCTAssertEqual(effective.skahaBaseURL, "https://ws-sf.canfar.net/skaha")
        XCTAssertEqual(effective.loginBaseURL, APIEndpoints().loginBaseURL, "Unresolved fields keep their defaults")
    }

    func testOverrideBeatsResolvedAndDefault() {
        var overrides = EndpointOverrides()
        overrides.set("https://my.private.host/skaha", for: .skahaBaseURL)
        let cache = resolved([.skahaBaseURL: "https://ws-sf.canfar.net/skaha"])
        let effective = EndpointResolution.effective(overrides: overrides, resolved: cache)
        XCTAssertEqual(effective.skahaBaseURL, "https://my.private.host/skaha")
    }

    func testSourceReportsPerFieldProvenance() {
        var overrides = EndpointOverrides()
        overrides.set("https://my.private.host/skaha", for: .skahaBaseURL)
        let cache = resolved([.archiveBaseURL: "https://archive.example.org"])

        XCTAssertEqual(EndpointResolution.source(for: .skahaBaseURL, overrides: overrides, resolved: cache), .override)
        XCTAssertEqual(EndpointResolution.source(for: .archiveBaseURL, overrides: overrides, resolved: cache), .resolved)
        XCTAssertEqual(EndpointResolution.source(for: .loginBaseURL, overrides: overrides, resolved: cache), .defaultValue)
    }

    // MARK: - Normalization

    func testBlankOverrideClearsInsteadOfStoringEmpty() {
        var overrides = EndpointOverrides()
        overrides.set("https://example.org", for: .archiveBaseURL)
        XCTAssertTrue(overrides.set("   ", for: .archiveBaseURL), "Clearing is a change")
        XCTAssertNil(overrides[.archiveBaseURL])
        XCTAssertTrue(overrides.isEmpty)
    }

    func testTrailingSlashesAreTrimmed() {
        var overrides = EndpointOverrides()
        overrides.set("https://example.org/skaha//", for: .skahaBaseURL)
        XCTAssertEqual(overrides[.skahaBaseURL], "https://example.org/skaha")
    }

    func testNoOpWriteReportsNoChange() {
        var overrides = EndpointOverrides()
        overrides.set("https://example.org", for: .archiveBaseURL)
        XCTAssertFalse(overrides.set("https://example.org/", for: .archiveBaseURL), "Same normalized value = no change")
    }

    // MARK: - Validation

    func testIsValidBaseAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(EndpointOverrides.isValidBase("https://ws-uv.canfar.net/skaha"))
        XCTAssertTrue(EndpointOverrides.isValidBase("http://vizier.china-vo.org/tap"))
    }

    func testIsValidBaseRejectsGarbage() {
        XCTAssertFalse(EndpointOverrides.isValidBase("not a url"))
        XCTAssertFalse(EndpointOverrides.isValidBase("ftp://example.org/files"))
        XCTAssertFalse(EndpointOverrides.isValidBase("https://"))
        XCTAssertFalse(EndpointOverrides.isValidBase(""))
    }

    // MARK: - Field metadata

    func testDefaultValuesMatchAPIEndpoints() {
        let defaults = APIEndpoints()
        XCTAssertEqual(EndpointField.loginBaseURL.defaultValue, defaults.loginBaseURL)
        XCTAssertEqual(EndpointField.registryBaseURL.defaultValue, defaults.registryBaseURL)
        XCTAssertEqual(EndpointField.archiveBaseURL.defaultValue, defaults.archiveBaseURL)
    }

    func testResolvableFieldsCarryResourceIDs() {
        XCTAssertEqual(EndpointField.loginBaseURL.resourceID, "ivo://cadc.nrc.ca/gms")
        XCTAssertEqual(EndpointField.skahaBaseURL.resourceID, "ivo://cadc.nrc.ca/skaha")
        XCTAssertEqual(EndpointField.storageBaseURL.resourceID, "ivo://cadc.nrc.ca/arc")
        XCTAssertEqual(EndpointField.archiveBaseURL.resourceID, "ivo://cadc.nrc.ca/argus")
        XCTAssertNil(EndpointField.externalBaseURL.resourceID)
        XCTAssertNil(EndpointField.registryBaseURL.resourceID)
        XCTAssertNil(EndpointField.acBaseURL.resourceID)
    }
}
