// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Failure modes for ``CAOM2Service.fetch(publisherID:)``.
enum CAOM2ServiceError: Error, LocalizedError {
    /// HTTP status indicates the response is gated behind CADC SSO. The
    /// detail viewer surfaces this as a polite "Sign in to view" message
    /// rather than a generic error — observation metadata for proprietary
    /// collections (e.g. NEOSSAT) is fetchable, just not anonymously.
    case authenticationRequired
    case observationNotFound
    case serverError(status: Int, body: String)
    case invalidPublisherID(String)
    case parse(CAOM2ParserError)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return String(localized: "This observation requires CADC sign-in.")
        case .observationNotFound:
            return String(localized: "Observation not found.")
        case .serverError(let status, let body):
            return "Metadata server returned HTTP \(status): \(body.prefix(200))"
        case .invalidPublisherID(let pid):
            return "Cannot derive observation URI from publisher ID: \(pid)"
        case .parse(let inner):
            return inner.errorDescription
        case .transport(let inner):
            return inner.localizedDescription
        }
    }
}

/// Fetches a single CAOM2 observation document from CADC.
///
/// Endpoint: `caom2ops/meta?ID=caom:{collection}/{observationID}`.
///
/// Note: the URI scheme accepted by the metadata service is **`caom:`**,
/// not the `ivo://` publisher form that appears in TAP results. The mapping
/// lives in ``CAOM2Observation/observationURI(fromPublisherID:)``.
actor CAOM2Service {
    private let session: URLSession

    /// In-memory cache keyed by observation URI. Same LRU discipline as
    /// `TAPClient.datalinkCache` — bounded so browsing 10 000 results
    /// doesn't bloat memory.
    private var cache: [String: CAOM2Observation] = [:]
    private var cacheOrder: [String] = []
    private static let cacheCapacity = 100

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch the CAOM2 observation document for the given publisher ID.
    /// Translates `ivo://...` → `caom:...` internally.
    func fetch(publisherID: String) async throws -> CAOM2Observation {
        guard let observationURI = CAOM2Observation.observationURI(fromPublisherID: publisherID) else {
            throw CAOM2ServiceError.invalidPublisherID(publisherID)
        }
        return try await fetch(observationURI: observationURI)
    }

    /// Fetch by canonical CAOM2 URI (`caom:COLLECTION/observationID`).
    func fetch(observationURI: String) async throws -> CAOM2Observation {
        if let cached = cache[observationURI] {
            promote(observationURI)
            return cached
        }

        guard var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.metaPath)") else {
            throw CAOM2ServiceError.transport(URLError(.badURL))
        }
        components.queryItems = [URLQueryItem(name: "ID", value: observationURI)]
        guard let url = components.url else {
            throw CAOM2ServiceError.transport(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CAOM2ServiceError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CAOM2ServiceError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            do {
                let observation = try CAOM2Parser.parse(data: data)
                insertIntoCache(observationURI, observation)
                return observation
            } catch let err as CAOM2ParserError {
                throw CAOM2ServiceError.parse(err)
            } catch {
                throw CAOM2ServiceError.transport(error)
            }
        case 401, 403:
            throw CAOM2ServiceError.authenticationRequired
        case 404:
            throw CAOM2ServiceError.observationNotFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CAOM2ServiceError.serverError(status: http.statusCode, body: body)
        }
    }

    // MARK: - LRU helpers

    private func promote(_ key: String) {
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
    }

    private func insertIntoCache(_ key: String, _ value: CAOM2Observation) {
        cache[key] = value
        cacheOrder.append(key)
        while cacheOrder.count > Self.cacheCapacity {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
