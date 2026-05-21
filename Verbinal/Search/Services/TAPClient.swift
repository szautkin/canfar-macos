// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Actor-based HTTP client for public CADC TAP and resolver services.
/// Does NOT use authentication — all endpoints are public.
actor TAPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - TAP Query

    /// Execute a synchronous TAP query against CADC's Argus service.
    /// Returns the raw CSV response text.
    ///
    /// Wrapped in `retrying(.default)`: 5xx, network drops, and DNS hiccups
    /// get one or two automatic retries with exponential backoff before
    /// surfacing the failure. 4xx (bad ADQL etc.) is *not* retried.
    func tapQuery(adql: String, maxRec: Int = TAPConfig.maxRecords) async throws -> String {
        try await tapQueryAt(
            endpoint: "\(TAPConfig.baseURL)\(TAPConfig.syncPath)",
            adql: adql,
            maxRec: maxRec
        )
    }

    /// TAP-1.1 sync POST against an arbitrary endpoint. Reused
    /// by VizieR / SIMBAD / any TAP-compliant service the agent
    /// might want to reach — same form-encoded ADQL wire shape,
    /// same retry policy on 5xx, same `MAXREC` semantics.
    /// Caller is responsible for picking the right endpoint URL
    /// and (for non-CADC services) any `FORMAT` other than CSV
    /// if their server doesn't speak that dialect.
    func tapQueryAt(endpoint: String, adql: String, maxRec: Int) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw SearchError.networkError("Invalid TAP URL")
        }

        return try await retrying(.default) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            let params = [
                "LANG": "ADQL",
                "FORMAT": TAPConfig.format,
                "QUERY": adql,
                "MAXREC": String(maxRec),
            ]

            request.httpBody = params
                .map { key, value in
                    let encodedKey = Self.formEncode(key)
                    let encodedValue = Self.formEncode(value)
                    return "\(encodedKey)=\(encodedValue)"
                }
                .joined(separator: "&")
                .data(using: .utf8)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            // Surface 5xx as `NetworkError.httpError` so the retry helper
            // can recognise it; map back to SearchError after the retry
            // loop gives up.
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if httpResponse.statusCode >= 500 {
                    throw NetworkError.httpError(httpResponse.statusCode, body)
                }
                throw SearchError.networkError("TAP query failed (HTTP \(httpResponse.statusCode)): \(body)")
            }

            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Execute a TAP query and parse results into rows.
    func tapQueryRows(adql: String, maxRec: Int = TAPConfig.maxRecords) async throws -> (headers: [String], rows: [[String]]) {
        let csv = try await tapQuery(adql: adql, maxRec: maxRec)
        return CSVParser.parse(csv)
    }

    /// VizieR cone search with mirror failover. Builds the canonical
    /// ADQL pattern (`CIRCLE`+`CONTAINS` against the catalogue's RA/Dec
    /// columns) and rotates through the public VizieR TAP mirrors when
    /// the primary host is unreachable.
    ///
    /// **Why failover.** The 2026-05-15 QA report documented that every
    /// call to `tap.cds.unistra.fr` returned `cannotFindHost` for an
    /// entire 12-hour user session — a DNS-level failure specific to
    /// that one VizieR host, while SIMBAD / NED resolved fine in the
    /// same session. A single hardcoded endpoint blocked an entire
    /// astronomical replication workflow; the fix is to treat the four
    /// public mirrors as interchangeable for catalogue-cone-search
    /// purposes (they all mirror the same VizieR corpus) and fall over
    /// when the lead host is unreachable.
    ///
    /// **Failover discipline.** Only host-specific errors (URLError, 5xx)
    /// trigger rotation — 4xx (bad ADQL, unknown catalogue) would give
    /// the same answer on every mirror, so we raise immediately rather
    /// than burn the budget. The final error surfaces every host that
    /// was tried so the user knows whether this is a "VizieR is down
    /// globally" or "your query is wrong" situation.
    ///
    /// `catalogue` is the VizieR catalogue identifier (e.g.
    /// `"V/97/catalog"` for Clement+2001 variables-in-globular-
    /// clusters). Defaults (`"RAJ2000"` / `"DEJ2000"`) cover the
    /// majority of VizieR holdings.
    func vizierConeSearch(
        catalogue: String,
        raDeg: Double,
        decDeg: Double,
        radiusDeg: Double,
        raColumn: String = "RAJ2000",
        decColumn: String = "DEJ2000",
        maxRec: Int = 500
    ) async throws -> (headers: [String], rows: [[String]]) {
        let adql = """
        SELECT TOP \(maxRec) *
        FROM "\(catalogue)"
        WHERE 1 = CONTAINS(
            POINT('ICRS', \(raColumn), \(decColumn)),
            CIRCLE('ICRS', \(raDeg), \(decDeg), \(radiusDeg))
        )
        """
        var attempts: [(host: String, error: Error)] = []
        for endpoint in Self.vizierEndpoints {
            do {
                let csv = try await tapQueryAt(endpoint: endpoint.syncURL, adql: adql, maxRec: maxRec)
                return CSVParser.parse(csv)
            } catch {
                if !Self.isHostFailoverWorthy(error) {
                    // 4xx / parse / catalogue-not-found: failing on this
                    // mirror means failing on all of them. Don't waste
                    // budget trying further hosts.
                    throw SearchError.networkError(
                        "vizier_cone_search at \(endpoint.host): \(error.localizedDescription) — not retrying other mirrors (looks like a query problem, not a host problem)."
                    )
                }
                attempts.append((endpoint.host, error))
            }
        }
        let tried = attempts.map(\.host).joined(separator: ", ")
        let lastReason = attempts.last?.error.localizedDescription ?? "unknown"
        throw SearchError.networkError(
            "vizier_cone_search exhausted all VizieR mirrors [\(tried)]; last error: \(lastReason). VizieR may be globally degraded — retry in a few minutes, or use astroquery from inside a Skaha session as a workaround."
        )
    }

    // MARK: - VizieR mirror registry

    /// One public VizieR TAP mirror — host + canonical `/sync` URL.
    /// `host` is exposed separately so error messages can surface the
    /// rotation path without parsing URLs back out.
    struct VizierEndpoint: Sendable, Equatable {
        let host: String
        let syncURL: String
    }

    /// Ordered fallback list of VizieR TAP mirrors. Try primary CDS
    /// first, fall back through CDS's legacy alias (different DNS
    /// zone — survives the exact failure mode the 2026-05-15 QA
    /// report observed on `cds.unistra.fr`), then ESAC (geographically
    /// distinct, separate operator), then the China-VO HTTP mirror
    /// (last-resort fallback for the case where TLS itself is what's
    /// broken). All four mirror the same VizieR catalogue corpus so a
    /// cone search returns equivalent data regardless of which one
    /// answers — modulo at-most-hours of replication lag on ESAC /
    /// China-VO for newly-ingested catalogues.
    static let vizierEndpoints: [VizierEndpoint] = [
        VizierEndpoint(
            host: "tap.cds.unistra.fr",
            syncURL: "https://tap.cds.unistra.fr/tap/sync"
        ),
        VizierEndpoint(
            host: "tapvizier.u-strasbg.fr",
            syncURL: "https://tapvizier.u-strasbg.fr/TAPVizieR/tap/sync"
        ),
        VizierEndpoint(
            host: "tapvizier.esac.esa.int",
            syncURL: "https://tapvizier.esac.esa.int/TAPVizieR/tap/sync"
        ),
        VizierEndpoint(
            host: "vizier.china-vo.org",
            syncURL: "http://vizier.china-vo.org/tap/sync"
        ),
    ]

    /// Predicate for "this error means *this host* is the problem,
    /// try the next one." Any `URLError` (DNS failure, TLS handshake,
    /// connection refused, timeout) is host-specific. Any 5xx from
    /// the server is host-specific. 4xx is *not* — the request is
    /// wrong and every mirror will tell us the same thing. Parse
    /// errors aren't either — the response came back, so the host
    /// works; the catalogue / column shape is the issue.
    static func isHostFailoverWorthy(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let net = error as? NetworkError {
            switch net {
            case .httpError(let code, _) where code >= 500 && code < 600:
                return true
            case .invalidResponse:
                return true
            default:
                return false
            }
        }
        // SearchError.networkError wraps both transport and 4xx via the
        // existing `tapQueryAt` path; only the transport-shaped ones
        // (which encapsulate URLError underneath) warrant failover.
        if let search = error as? SearchError, case .networkError(let msg) = search {
            // Cheap heuristic: messages from URLError carry "could not
            // be found" / "could not connect" / "timed out" / "internet
            // connection appears to be offline". Messages from a 4xx
            // wrap server body text and don't.
            let lc = msg.lowercased()
            let transportMarkers = [
                "could not be found",
                "could not connect",
                "timed out",
                "appears to be offline",
                "network connection was lost",
                "tls",
                "ssl",
                "dns",
            ]
            return transportMarkers.contains(where: lc.contains)
        }
        return false
    }

    // MARK: - Target Resolver

    /// Resolve a target name to coordinates using the CADC target resolver.
    func resolveTarget(name: String, service: String = "all") async throws -> ResolverResult {
        guard var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.resolverPath)") else {
            throw SearchError.networkError("Invalid resolver URL")
        }
        components.queryItems = [
            URLQueryItem(name: "target", value: name),
            URLQueryItem(name: "service", value: service.lowercased()),
            URLQueryItem(name: "format", value: "ascii"),
            URLQueryItem(name: "detail", value: "max"),
            URLQueryItem(name: "cached", value: "true"),
        ]

        guard let url = components.url else {
            throw SearchError.networkError("Invalid resolver URL")
        }

        var request = URLRequest(url: url)
        // The CADC target resolver consults SIMBAD / NED / VizieR
        // upstream, all of which can stall. 60s tolerates a slow
        // upstream lookup without falsely surfacing networkError.
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SearchError.networkError("Target resolution failed for \"\(name)\"")
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return parseResolverResponse(text, target: name, service: service)
    }

    // MARK: - DataLink

    /// LRU cap for the in-memory DataLink cache. Browsing 10 000 results
    /// should not bloat memory unboundedly; once we pass this many distinct
    /// publisher IDs, the least-recently-inserted entries are evicted.
    private static let datalinkCacheCapacity = 200

    /// In-memory cache for DataLink results keyed by publisherID.
    /// Access-order is maintained by `datalinkCacheOrder` — on hit we re-append
    /// the key to the end; on miss we append and trim from the front.
    private var datalinkCache: [String: DataLinkResult] = [:]
    private var datalinkCacheOrder: [String] = []

    /// Fetch thumbnail and preview image URLs for an observation via DataLink.
    func fetchDataLinks(publisherID: String) async throws -> DataLinkResult {
        if let cached = datalinkCache[publisherID] {
            // Promote to most-recently-used.
            if let idx = datalinkCacheOrder.firstIndex(of: publisherID) {
                datalinkCacheOrder.remove(at: idx)
            }
            datalinkCacheOrder.append(publisherID)
            return cached
        }

        guard var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.datalinkPath)") else {
            throw SearchError.networkError("Invalid DataLink URL")
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: publisherID),
            URLQueryItem(name: "request", value: "downloads-only"),
        ]

        guard let url = components.url else {
            throw SearchError.networkError("Invalid DataLink URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/x-votable+xml", forHTTPHeaderField: "Accept")
        // 15s was a holdover from when DataLink was reliably fast;
        // it routinely takes 20–30s now and was timing out in the
        // get_data_links MCP path. Match the rest of the CADC stack.
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }

        let xml = String(data: data, encoding: .utf8) ?? ""
        let result = DataLinkResult.fromVOTable(xml)
        insertIntoCache(publisherID: publisherID, result: result)
        return result
    }

    /// Insert into the DataLink cache, evicting oldest entries past the cap.
    private func insertIntoCache(publisherID: String, result: DataLinkResult) {
        datalinkCache[publisherID] = result
        datalinkCacheOrder.append(publisherID)
        while datalinkCacheOrder.count > Self.datalinkCacheCapacity {
            let oldest = datalinkCacheOrder.removeFirst()
            datalinkCache.removeValue(forKey: oldest)
        }
    }

    // MARK: - URL Builders

    /// Build single-file download URL for an observation.
    static func downloadURL(publisherID: String) -> URL? {
        var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.downloadPath)")
        components?.queryItems = [URLQueryItem(name: "ID", value: publisherID)]
        return components?.url
    }

    /// Build CAOM2 UI observation detail URL.
    static func detailURL(publisherID: String) -> URL? {
        // Strip trailing /productID to get observation-level URI
        let observationURI: String
        if let lastSlash = publisherID.lastIndex(of: "/") {
            observationURI = String(publisherID[publisherID.startIndex..<lastSlash])
        } else {
            observationURI = publisherID
        }
        var components = URLComponents(string: CADCExternalURLs.caom2uiView)
        components?.queryItems = [URLQueryItem(name: "ID", value: observationURI)]
        return components?.url
    }

    // MARK: - Private

    /// Parse the resolver's key=value text format into a ResolverResult.
    private func parseResolverResponse(_ text: String, target: String, service: String) -> ResolverResult {
        var dict: [String: String] = [:]
        for line in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            // Trim newlines as well as whitespace — CADC resolver lines
            // are CRLF-terminated, and a trailing \r in `coordsRA`
            // makes `Double(coordsRA)` return nil downstream, which
            // surfaces as a spurious `unknownTarget` error in
            // `search_observations(target:)`. (Closes F-9 and F-12 from
            // the 2026-04-29 platform review.)
            var key = String(line[line.startIndex..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "time(ms)" { key = "time" }
            dict[key] = value
        }

        return ResolverResult(
            target: dict["target"] ?? target,
            service: dict["service"] ?? service,
            coordsRA: dict["ra"] ?? "",
            coordsDec: dict["dec"] ?? "",
            coordsys: dict["coordsys"],
            objectType: dict["otype"],
            morphologyType: dict["mtype"]
        )
    }

    /// Percent-encode a string for application/x-www-form-urlencoded.
    /// Unlike .urlQueryAllowed, this properly encodes quotes, ampersands, plus signs, etc.
    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private static func formEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? string
    }
}
