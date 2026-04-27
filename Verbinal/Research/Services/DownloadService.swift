// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

/// Downloads observation files from CADC.
/// Uses URLSession.download to fetch to a temp file, then moves to user-chosen location.
actor DownloadService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Downloads")
    private let session: URLSession
    private let endpoints: APIEndpoints

    init(session: URLSession = .shared, endpoints: APIEndpoints = APIEndpoints()) {
        self.session = session
        self.endpoints = endpoints
    }

    /// Download an observation file to a temporary location.
    /// Uses DataLink #this semantic for direct FITS (no tar), falls back to /pkg endpoint.
    func downloadToTemp(publisherID: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        // Step 1: Try DataLink to get direct file URL (matches Windows approach)
        let directURL = await resolveDirectFileURL(publisherID: publisherID)

        // Step 2: Use direct URL if available, otherwise fall back to /pkg (tar archive)
        let url: URL
        if let directURL {
            Self.logger.info("Using DataLink direct URL: \(directURL.lastPathComponent)")
            url = directURL
        } else {
            guard var components = URLComponents(string: endpoints.caom2PkgURL) else {
                throw SearchError.networkError("Invalid download URL")
            }
            components.queryItems = [URLQueryItem(name: "ID", value: publisherID)]
            guard let pkgURL = components.url else {
                throw SearchError.networkError("Invalid download URL")
            }
            Self.logger.info("DataLink unavailable, falling back to /pkg")
            url = pkgURL
        }

        let request = URLRequest(url: url)
        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SearchError.networkError("Download failed (HTTP \(code))")
        }

        // Extract filename from Content-Disposition header or URL
        let suggestedFilename = extractFilename(from: httpResponse, publisherID: publisherID)

        // Move temp file to a location that won't be cleaned up immediately
        let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFilename)
        if FileManager.default.fileExists(atPath: stableTemp.path) {
            try FileManager.default.removeItem(at: stableTemp)
        }
        try FileManager.default.moveItem(at: tempURL, to: stableTemp)

        Self.logger.info("Downloaded to temp: \(suggestedFilename)")
        return (stableTemp, suggestedFilename)
    }

    /// Delete a file at a given URL.
    func deleteFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Get file size at a URL.
    func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.size] as? Int64
    }

    // MARK: - DataLink Resolution

    /// Resolve DataLink to find direct FITS file URL (#this semantic).
    /// Returns nil if DataLink fails or has no direct files.
    private func resolveDirectFileURL(publisherID: String) async -> URL? {
        guard var components = URLComponents(string: endpoints.datalinkURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "id", value: publisherID),
            URLQueryItem(name: "request", value: "downloads-only"),
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/x-votable+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else { return nil }
            let result = DataLinkResult.fromVOTable(xml)
            return result.bestDirectFileURL
        } catch {
            Self.logger.warning("DataLink resolution failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private func extractFilename(from response: HTTPURLResponse, publisherID: String) -> String {
        // Try Content-Disposition header
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=") {
            let raw = String(disposition[range.upperBound...])
                .trimmingCharacters(in: .init(charactersIn: "\"' "))
            let safe = Self.sanitizeFilename(raw)
            if !safe.isEmpty { return safe }
        }

        // Try suggested filename from response
        if let suggested = response.suggestedFilename, !suggested.isEmpty, suggested != "Unknown" {
            return Self.sanitizeFilename(suggested)
        }

        // Build from publisherID: ivo://cadc.nrc.ca/COLLECTION?OBSID/PRODUCTID
        let productID: String
        if let lastSlash = publisherID.lastIndex(of: "/") {
            productID = String(publisherID[publisherID.index(after: lastSlash)...])
        } else if let questionMark = publisherID.lastIndex(of: "?") {
            productID = String(publisherID[publisherID.index(after: questionMark)...])
        } else {
            productID = "observation"
        }

        // Check content type for extension
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ext: String
        if contentType.contains("tar") {
            ext = ".tar"
        } else if contentType.contains("fits") {
            ext = ".fits"
        } else if contentType.contains("gzip") || contentType.contains("gz") {
            ext = ".fits.gz"
        } else {
            ext = ""
        }

        return Self.sanitizeFilename(productID.replacingOccurrences(of: "/", with: "_") + ext)
    }

    /// Strip any path separators and parent-directory traversal from a server-supplied
    /// filename so it cannot escape the temp directory when appended.
    private static func sanitizeFilename(_ name: String) -> String {
        // Keep only the last path component, then strip illegal characters.
        let last = (name as NSString).lastPathComponent
        let disallowed = CharacterSet(charactersIn: "/\\:\u{0}")
        return last.components(separatedBy: disallowed).joined()
    }
}
