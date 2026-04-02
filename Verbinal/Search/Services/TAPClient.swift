// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

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
    func tapQuery(adql: String, maxRec: Int = TAPConfig.maxRecords) async throws -> String {
        guard let url = URL(string: "\(TAPConfig.baseURL)\(TAPConfig.syncPath)") else {
            throw SearchError.networkError("Invalid TAP URL")
        }

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
            throw SearchError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SearchError.networkError("TAP query failed (HTTP \(httpResponse.statusCode)): \(body)")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Execute a TAP query and parse results into rows.
    func tapQueryRows(adql: String, maxRec: Int = TAPConfig.maxRecords) async throws -> (headers: [String], rows: [[String]]) {
        let csv = try await tapQuery(adql: adql, maxRec: maxRec)
        return CSVParser.parse(csv)
    }

    // MARK: - Target Resolver

    /// Resolve a target name to coordinates using the CADC target resolver.
    func resolveTarget(name: String, service: String = "all") async throws -> ResolverResult {
        var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.resolverPath)")!
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
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SearchError.networkError("Target resolution failed for \"\(name)\"")
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return parseResolverResponse(text, target: name, service: service)
    }

    // MARK: - DataLink

    /// In-memory cache for DataLink results keyed by publisherID.
    private var datalinkCache: [String: DataLinkResult] = [:]

    /// Fetch thumbnail and preview image URLs for an observation via DataLink.
    func fetchDataLinks(publisherID: String) async throws -> DataLinkResult {
        if let cached = datalinkCache[publisherID] {
            return cached
        }

        var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.datalinkPath)")!
        components.queryItems = [
            URLQueryItem(name: "id", value: publisherID),
            URLQueryItem(name: "request", value: "downloads-only"),
        ]

        guard let url = components.url else {
            throw SearchError.networkError("Invalid DataLink URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/x-votable+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return DataLinkResult(thumbnails: [], previews: [])
        }

        let xml = String(data: data, encoding: .utf8) ?? ""
        let result = DataLinkResult.fromVOTable(xml)
        datalinkCache[publisherID] = result
        return result
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
            var key = String(line[line.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
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
