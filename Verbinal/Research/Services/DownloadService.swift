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
    private let caom2: CAOM2Service
    private let tasks: TaskRegistry
    /// Where each download is recorded — here, whoever asks (plan 23 C).
    private let changes: ChangeLog

    init(
        session: URLSession = .shared,
        endpoints: APIEndpoints = TAPConfig.endpoints,
        caom2: CAOM2Service = CAOM2Service(),
        tasks: TaskRegistry = .shared,
        changes: ChangeLog = .shared
    ) {
        self.tasks = tasks
        self.changes = changes
        self.session = session
        self.endpoints = endpoints
        self.caom2 = caom2
    }

    /// Download an observation file to a temporary location.
    /// Prefers DataLink `#this`, then CAOM-2 `productType: science`
    /// artifacts (the ESPaDOnS / package-fallback path that otherwise
    /// yields a 0-byte `pkg-*.txt`), then `/caom2ops/pkg`.
    /// Fetches the observation's file — on the activity bar, whoever asked.
    func downloadToTemp(publisherID: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        try await tasks.track(.download, Self.label(publisherID)) { _ in
            try await self.changes.run("download_observation", "observation \(publisherID)") {
                try await self.fetchWhole(publisherID: publisherID)
            }
        }
    }

    /// Fetches one of the observation's files by name — `oezt010e0_x1d.fits`
    /// rather than the `_flt` the observation's best pick would be — from
    /// DataLink, else the archive's record of its plane. Names come from
    /// `get_data_links` (`files[].filename`, `caom2Artifacts[].filename`).
    func downloadToTemp(publisherID: String, file: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        try await tasks.track(.download, Self.label(publisherID, file: file)) { _ in
            try await self.changes.run("download_observation", "\(file) of observation \(publisherID)") {
                try await self.fetch(file, of: publisherID)
            }
        }
    }

    private func fetch(_ file: String, of publisherID: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        if let link = await resolveDataLink(publisherID: publisherID).directFiles.first(where: { $0.filename == file }) {
            return try await fetchToTemp(url: link.url, publisherID: publisherID, suggested: file)
        }
        let artifact = await planeArtifacts(publisherID: publisherID)
            .first { ($0.uri as NSString).lastPathComponent == file }
        guard let artifact, let url = endpoints.dataPubURL(forArtifactURI: artifact.uri) else {
            // Another plane of the observation may hold it: get_data_links lists
            // every plane's files. Said, with that plane's ID — never fetched
            // into this one's record (plan 30 D).
            if let sibling = await siblingHolding(file, of: publisherID) {
                throw SearchError.networkError("\(file) is in \(sibling), not \(publisherID): download it from that publisher ID.")
            }
            throw SearchError.networkError("\(publisherID) has no file named \(file) — get_data_links lists its files.")
        }
        return try await fetchToTemp(url: url, publisherID: publisherID, suggested: file)
    }

    private func fetchWhole(publisherID: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        let datalink = await resolveDataLink(publisherID: publisherID)
        if let directURL = datalink.bestDirectFileURL {
            Self.logger.info("Using DataLink direct URL: \(directURL.lastPathComponent)")
            return try await fetchToTemp(url: directURL, publisherID: publisherID)
        }
        if let artifact = await resolveScienceArtifact(publisherID: publisherID) {
            Self.logger.info("Using CAOM-2 science artifact: \(artifact.filename)")
            return try await fetchToTemp(url: artifact.url, publisherID: publisherID, suggested: artifact.filename)
        }
        guard var components = URLComponents(string: endpoints.caom2PkgURL) else {
            throw SearchError.networkError("Invalid download URL")
        }
        components.queryItems = [URLQueryItem(name: "ID", value: publisherID)]
        guard let pkgURL = components.url else {
            throw SearchError.networkError("Invalid download URL")
        }
        Self.logger.info("DataLink and CAOM-2 artifacts unavailable, falling back to /pkg")
        let result = try await fetchToTemp(url: pkgURL, publisherID: publisherID, requireUsable: false)
        guard let problem = DownloadedFileCheck.problem(at: result.tempURL) else {
            return result
        }
        // An empty package (0 bytes, or an empty tar) — try artifacts once
        // more in case CAOM-2 was briefly unavailable on the first pass.
        try? deleteFile(at: result.tempURL)
        if let artifact = await resolveScienceArtifact(publisherID: publisherID) {
            Self.logger.info("pkg was empty; retrying CAOM-2 science artifact: \(artifact.filename)")
            return try await fetchToTemp(url: artifact.url, publisherID: publisherID, suggested: artifact.filename)
        }
        let faultNote = datalink.faults.isEmpty
            ? ""
            : " (DataLink: \(datalink.faults.joined(separator: "; ")))"
        throw SearchError.networkError(
            "\(problem.message) Nothing to keep for \(publisherID): no DataLink #this and no CAOM-2 science artifact\(faultNote)."
        )
    }

    /// Download `url` — a cutout, or any file CADC serves — to a temporary
    /// file named `suggestedFilename`.
    func downloadToTemp(url: URL, suggestedFilename: String, publisherID: String) async throws -> (tempURL: URL, suggestedFilename: String) {
        try await tasks.track(.download, Self.label(publisherID, file: suggestedFilename)) { _ in
            try await self.changes.run("download_cutout", "\(suggestedFilename) of observation \(publisherID)") {
                try await self.fetchToTemp(url: url, publisherID: publisherID, suggested: suggestedFilename)
            }
        }
    }

    /// "Download M31 (MegaPipe…)" — the observation, or the file when there is one.
    private static func label(_ publisherID: String, file: String? = nil) -> String {
        String(localized: "Download \(file ?? PublisherID(publisherID)?.observationID ?? publisherID)")
    }

    private func fetchToTemp(
        url: URL,
        publisherID: String,
        suggested: String? = nil,
        requireUsable: Bool = true
    ) async throws -> (tempURL: URL, suggestedFilename: String) {
        let request = URLRequest(url: url)
        let (tempURL, response) = try await session.recordedDownload(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SearchError.networkError("Download failed (HTTP \(code))")
        }

        var name = suggested ?? extractFilename(from: httpResponse, publisherID: publisherID)
        name = Self.uniqueSuggestedFilename(publisherID: publisherID, suggested: name)

        let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: stableTemp.path) {
            try FileManager.default.removeItem(at: stableTemp)
        }
        try FileManager.default.moveItem(at: tempURL, to: stableTemp)

        let size = fileSize(at: stableTemp) ?? 0
        // The announced length only counts when the body was not re-encoded on the way.
        let encoded = !(["", "identity"].contains(httpResponse.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? ""))
        let expected = encoded ? nil : httpResponse.expectedContentLength
        if requireUsable, let problem = DownloadedFileCheck.problem(at: stableTemp, expectedBytes: expected) {
            try? deleteFile(at: stableTemp)
            throw SearchError.networkError("\(name): \(problem.message)")
        }

        Self.logger.info("Downloaded to temp: \(name) (\(size) bytes)")
        return (stableTemp, name)
    }

    /// The artifacts of the plane `publisherID` names — only that plane's:
    /// a MegaPipe tile's u-band ID must not fetch its g-band sibling. Every
    /// plane's when the ID names no product.
    /// The publisher ID of the observation's other plane that holds `file`.
    private func siblingHolding(_ file: String, of publisherID: String) async -> String? {
        guard let observation = try? await caom2.fetch(publisherID: publisherID),
              let plane = observation.planes.first(where: { plane in
                  plane.artifacts.contains { ($0.uri as NSString).lastPathComponent == file }
              }) else { return nil }
        return PublisherID.sibling(of: publisherID, product: plane.productID).flatMap { $0 == publisherID ? nil : $0 }
    }

    private func planeArtifacts(publisherID: String) async -> [CAOM2Observation.Artifact] {
        guard let observation = try? await caom2.fetch(publisherID: publisherID) else { return [] }
        guard let id = PublisherID(publisherID), !id.productID.isEmpty else {
            return observation.planes.flatMap(\.artifacts)
        }
        return ResearchRecordDetails.plane(of: id, in: observation)?.artifacts ?? []
    }

    /// Prefer uncompressed FITS science artifacts, then any science product.
    private func resolveScienceArtifact(publisherID: String) async -> (url: URL, filename: String)? {
        var science: [(url: URL, filename: String, length: Int64, uncompressed: Bool)] = []
        for a in await planeArtifacts(publisherID: publisherID) {
            let type = (a.productType ?? "").lowercased()
            guard type == "science" else { continue }
            guard let url = endpoints.dataPubURL(forArtifactURI: a.uri) else { continue }
            let filename = (a.uri as NSString).lastPathComponent
            let lower = filename.lowercased()
            let uncompressed = lower.hasSuffix(".fits") || lower.hasSuffix(".fit") || lower.hasSuffix(".fts")
            science.append((url, filename, a.contentLength ?? 0, uncompressed))
        }
        let best = science.first(where: \.uncompressed) ?? science.max(by: { $0.length < $1.length })
        return best.map { ($0.url, $0.filename) }
    }

    /// Make pkg-fallback names unique per observation so bulk downloads
    /// don't collide on a shared `pkg.txt`.
    static func uniqueSuggestedFilename(publisherID: String, suggested: String) -> String {
        let safe = sanitizeFilename(suggested)
        let generic = safe.isEmpty
            || safe.lowercased().hasPrefix("pkg")
            || safe.lowercased() == "unknown"
        let derived = filename(fromPublisherID: publisherID, contentType: generic ? "application/fits" : "")
        if generic {
            return derived.isEmpty ? "observation.fits" : derived
        }
        return safe
    }

    /// Delete a file at a given URL.
    func deleteFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Delete a file, logging (rather than throwing) any failure so callers
    /// in fire-and-forget cleanup paths — save-panel cancel, observation
    /// delete — don't have to swallow disk errors with a bare `try?`.
    ///
    /// A missing file is treated as success (the `deleteFile` guard makes it
    /// a no-op). Returns `false` only when an actual removal failed (e.g.
    /// permission denied, device offline), after writing a warning to the
    /// unified log under the `Downloads` category for diagnostics.
    @discardableResult
    func deleteFileLoggingFailure(at url: URL) -> Bool {
        do {
            try deleteFile(at: url)
            return true
        } catch {
            Self.logger.warning(
                "Failed to delete file at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Get file size at a URL.
    func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.size] as? Int64
    }

    // MARK: - DataLink Resolution

    /// Resolve DataLink to find direct FITS file URL (#this semantic).
    /// Returns an empty result if DataLink fails.
    private func resolveDataLink(publisherID: String) async -> DataLinkResult {
        guard var components = URLComponents(string: endpoints.datalinkURL) else {
            return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: publisherID),
            URLQueryItem(name: "request", value: "downloads-only"),
        ]
        guard let url = components.url else {
            return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/x-votable+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.recordedData(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else {
                return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
            }
            return DataLinkResult.fromVOTable(xml)
        } catch {
            Self.logger.warning("DataLink resolution failed: \(error.localizedDescription)")
            return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }
    }

    // MARK: - Private

    // `internal` (not `private`) so the filename derivation/sanitization is
    // unit-testable without a live download.
    func extractFilename(from response: HTTPURLResponse, publisherID: String) -> String {
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

        // Fall back to a name derived from the publisher id + content type.
        return Self.filename(
            fromPublisherID: publisherID,
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? ""
        )
    }

    /// Derive a safe filename from a CADC publisher id
    /// (`ivo://cadc.nrc.ca/COLLECTION?OBSID/PRODUCTID`) and the response
    /// content type, for when the server gives us no usable Content-Disposition
    /// or suggested name. Pure + `internal` so it can be unit-tested directly.
    static func filename(fromPublisherID publisherID: String, contentType: String) -> String {
        let productID: String
        if let lastSlash = publisherID.lastIndex(of: "/") {
            productID = String(publisherID[publisherID.index(after: lastSlash)...])
        } else if let questionMark = publisherID.lastIndex(of: "?") {
            productID = String(publisherID[publisherID.index(after: questionMark)...])
        } else {
            productID = "observation"
        }

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

        return sanitizeFilename(productID.replacingOccurrences(of: "/", with: "_") + ext)
    }

    /// Strip any path separators and parent-directory traversal from a server-supplied
    /// filename so it cannot escape the temp directory when appended.
    static func sanitizeFilename(_ name: String) -> String {
        // Keep only the last path component, then strip illegal characters.
        let last = (name as NSString).lastPathComponent
        let disallowed = CharacterSet(charactersIn: "/\\:\u{0}")
        return last.components(separatedBy: disallowed).joined()
    }
}
