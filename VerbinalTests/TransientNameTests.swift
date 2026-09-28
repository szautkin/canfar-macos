// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// A transient's name, however it is written, reaches the object
/// (plan 15 R3, QA M12: `AT 2023ixf` failed; `SN2023ixf` resolved).
final class TransientNameTests: XCTestCase {

    func testTheDesignationsOfATransient() {
        for name in ["AT 2023ixf", "AT2023ixf", "SN 2023ixf", "sn2023ixf", "2023ixf", " TDE 2019dsg "] {
            XCTAssertNotNil(TransientName(name), name)
        }
        XCTAssertEqual(TransientName("AT 2023ixf")?.core, "2023ixf")
        for name in ["M31", "NGC 1234", "2023", "SN 1987", "Europa", "J0800+3051"] {
            XCTAssertNil(TransientName(name), name)
        }
        XCTAssertEqual(TransientName("AT 2023ixf")?.alternates(to: "AT 2023ixf"), ["SN 2023ixf", "SN2023ixf", "AT2023ixf"])
    }

    /// The resolver finds nothing for the AT name and the SN name for NED.
    func testAnATNameResolvesThroughItsSNSpelling() async throws {
        final class Asked: @unchecked Sendable { var names: [String] = [] }
        let asked = Asked()
        MockURLProtocol.requestHandler = { request in
            let target = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "target" }?.value ?? ""
            asked.names.append(target)
            guard target == "SN 2023ixf" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 425, httpVersion: nil, headerFields: nil)!,
                        Data("error=Target not found\n".utf8))
            }
            let body = "target=SN 2023ixf\nservice=ned(ned.ipac.caltech.edu)\ncoordsys=ICRS\nra=210.910675\ndec=54.31165\notype=SN\n"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let resolver = TargetResolverService(tapClient: TAPClient(session: MockURLProtocol.mockSession()))

        let found = try await resolver.resolve(target: "AT 2023ixf", service: .all)
        XCTAssertEqual(found.coordsRA, "210.910675")
        XCTAssertEqual(asked.names, ["AT 2023ixf", "SN 2023ixf"])

        do {
            _ = try await resolver.resolve(target: "AT 2099zzz", service: .all)
            XCTFail("nothing to find")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\"SN2099zzz\""), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("VizieR"), error.localizedDescription)
        }
    }

    /// A 200 answer that says it found nothing is not a position at 0, 0.
    func testAMissAnsweredWith200IsAMiss() async {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("error=Target not found\ntarget=Nowhere\nra=0.0\ndec=0.0\n".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let client = TAPClient(session: MockURLProtocol.mockSession())
        do {
            _ = try await client.resolveTarget(name: "Nowhere")
            XCTFail("a miss is not a position")
        } catch {}
    }
}
