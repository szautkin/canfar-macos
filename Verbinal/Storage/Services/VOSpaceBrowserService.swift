// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Actor for browsing and managing VOSpace files via the ARC REST API.
actor VOSpaceBrowserService {
    private let network: NetworkClient

    /// VOSpace base URLs. Defaults match `APIEndpoints.storageBaseURL` (the
    /// `nodes/home` form) plus the parallel `files/home` form for binary
    /// transfer. Both share the same canfar.net host the rest of the app
    /// uses; if `APIEndpoints` ever moves to a different host the storage
    /// URLs follow because they're derived from `nodesBase` not hand-typed.
    private let nodesBase: String
    private let filesBase: String
    private static let vosPrefix = "vos://cadc.nrc.ca~arc/home"

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.nodesBase = endpoints.storageBaseURL
        // Derive the files base from the nodes base — they're symmetric paths.
        self.filesBase = endpoints.storageBaseURL.replacingOccurrences(of: "/nodes/home", with: "/files/home")
    }

    /// Percent-encode a single path segment (slashes are preserved in input by the caller
    /// splitting on `/` first). VOSpace filenames legally include `#`, `?`, `%`, spaces.
    private static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }

    /// Encode a `/`-separated path, preserving separators but encoding each segment.
    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeSegment(String($0)) }
            .joined(separator: "/")
    }

    // MARK: - List

    func listNodes(username: String, path: String = "", limit: Int = 500) async throws -> [VOSpaceNode] {
        let basePath = path.isEmpty ? Self.encodeSegment(username) : "\(Self.encodeSegment(username))/\(Self.encodePath(path))"
        let urlString = "\(nodesBase)/\(basePath)?limit=\(limit)"
        let (data, _) = try await network.get(urlString, accept: "text/xml")
        guard let xml = String(data: data, encoding: .utf8) else {
            throw VOSpaceError.invalidResponse
        }
        return VOSpaceXMLParser.parseNodeList(xml)
    }

    // MARK: - Download

    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String) {
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(path))"
        let (data, _) = try await network.get(urlString)
        let filename = URL(fileURLWithPath: (path as NSString).lastPathComponent).lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL)
        return (tempURL, filename)
    }

    // MARK: - Bounded read into memory

    /// Result of an agent-visible bounded read. `totalBytes` is the
    /// full file size when the server reports it via `Content-Range`;
    /// `nil` when the server didn't honour the `Range:` header (it
    /// returned 200 with the whole body — we still truncate before
    /// surfacing) or omitted `Content-Range` entirely.
    struct FetchResult: Sendable {
        let data: Data
        let totalBytes: Int?
    }

    /// Read a bounded slice of a VOSpace file directly into memory,
    /// for `read_vospace_file` — the agent-visible counterpart to
    /// `downloadFile`, which writes to the user's local Downloads
    /// and is therefore invisible to the agent. Uses HTTP
    /// `Range: bytes=offset-(offset+maxBytes-1)` to ask the ARC
    /// REST endpoint for just the requested slice; if the server
    /// ignores the Range header (200 instead of 206), we still
    /// truncate the local buffer at `maxBytes` so the caller's
    /// memory contract is honoured.
    ///
    /// Closes the QA finding from 2026-05-15: "three of eight
    /// Skaha jobs in this engagement existed solely to cat file
    /// contents back through stdout because the agent couldn't
    /// see what it just wrote." One round-trip here replaces an
    /// entire follow-up job.
    func fetchBytes(
        username: String,
        path: String,
        offset: Int,
        maxBytes: Int
    ) async throws -> FetchResult {
        guard maxBytes > 0 else {
            throw VOSpaceError.operationFailed("fetchBytes maxBytes must be > 0; got \(maxBytes)")
        }
        guard offset >= 0 else {
            throw VOSpaceError.operationFailed("fetchBytes offset must be >= 0; got \(offset)")
        }
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(path))"
        let rangeEnd = offset + maxBytes - 1
        let headers = ["Range": "bytes=\(offset)-\(rangeEnd)"]
        let (data, response) = try await network.get(urlString, additionalHeaders: headers)
        let totalBytes = Self.parseContentRangeTotal(response)
        // Defensive truncation: if the server ignored Range and
        // sent us the whole file (some VOSpace deployments don't
        // implement byte-ranges on all paths), respect the
        // caller's maxBytes contract anyway.
        let bounded = data.count > maxBytes ? data.prefix(maxBytes) : data
        return FetchResult(data: Data(bounded), totalBytes: totalBytes)
    }

    /// Parse `Content-Range: bytes 0-99/1000` and return the total
    /// (1000 in the example). Returns nil for `*` (size unknown
    /// server-side) or when the header is absent / malformed.
    private static func parseContentRangeTotal(_ response: HTTPURLResponse) -> Int? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let totalStr = header[header.index(after: slash)...]
        if totalStr == "*" { return nil }
        return Int(totalStr)
    }

    // MARK: - Upload

    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(remotePath))"

        // Sandbox: the source file came from an NSOpenPanel pick by the user,
        // possibly in an earlier transaction. Re-grant access for the read
        // window. The pair is a no-op for files the sandbox already trusts
        // (e.g., temp dir), so it's safe to apply universally.
        let didStart = fileURL.startAccessingSecurityScopedResource()
        defer { if didStart { fileURL.stopAccessingSecurityScopedResource() } }

        // Stream the file from disk rather than buffering the whole payload
        // in memory — important for FITS / data-cube uploads that easily
        // exceed available RAM.
        do {
            _ = try await network.putFile(
                urlString,
                fileURL: fileURL,
                contentType: "application/octet-stream",
                timeout: 300
            )
        } catch {
            throw VOSpaceError.operationFailed("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Folder

    func createFolder(username: String, parentPath: String, folderName: String) async throws {
        let fullPath = parentPath.isEmpty ? "\(username)/\(folderName)" : "\(username)/\(parentPath)/\(folderName)"
        let nodeURI = "\(Self.vosPrefix)/\(fullPath)"
        let xml = VOSpaceXMLParser.buildContainerNodeXml(nodeURI: nodeURI)

        let urlString = "\(nodesBase)/\(Self.encodePath(fullPath))"
        guard let body = xml.data(using: .utf8) else {
            throw VOSpaceError.operationFailed("Could not encode folder XML")
        }
        do {
            _ = try await network.put(urlString, body: body, contentType: "text/xml")
        } catch {
            throw VOSpaceError.operationFailed("Create folder failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete

    func deleteNode(username: String, path: String) async throws {
        let urlString = "\(nodesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(path))"
        let response = try await network.delete(urlString)
        guard (200...299).contains(response.statusCode) else {
            throw VOSpaceError.operationFailed("Delete failed (HTTP \(response.statusCode))")
        }
    }
}

// MARK: - Errors

enum VOSpaceError: LocalizedError {
    case invalidResponse
    case invalidPath
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid VOSpace response"
        case .invalidPath: return "Invalid path"
        case .operationFailed(let msg): return msg
        }
    }
}
