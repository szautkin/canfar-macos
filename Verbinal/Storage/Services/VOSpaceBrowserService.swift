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

    /// Strip `/home/<user>` (and `..`) so MCP and the Storage UI share one
    /// path contract: relative-from-home, absolute home prefixes accepted.
    private func relativePath(_ path: String, username: String) throws -> String {
        do {
            return try VOSpaceRelativePath.normalize(path, username: username)
        } catch VOSpaceRelativePath.Error.traversal {
            throw VOSpaceError.invalidPath
        }
    }

    func listNodes(username: String, path: String = "", limit: Int = 500) async throws -> [VOSpaceNode] {
        let relative = try relativePath(path, username: username)
        let basePath = relative.isEmpty ? Self.encodeSegment(username) : "\(Self.encodeSegment(username))/\(Self.encodePath(relative))"
        // `detail=max` matches the Windows client (`StorageNodeListUrl`) —
        // without it ARC returns bare nodes and the Modified/Size columns
        // stay empty because `#date` / `#length` properties are omitted.
        let urlString = "\(nodesBase)/\(basePath)?detail=max&limit=\(limit)"
        let (data, _) = try await network.get(urlString, accept: "text/xml")
        guard let xml = String(data: data, encoding: .utf8) else {
            throw VOSpaceError.invalidResponse
        }
        return VOSpaceXMLParser.parseNodeList(xml)
    }

    // MARK: - Download

    /// Protocol / agent-facing entry — no progress. The Storage UI uses the
    /// overload below so large FITS downloads can drive the shared transfer bar.
    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String) {
        try await downloadFile(username: username, path: path, expectedTotal: 0, onProgress: nil)
    }

    /// Streams to a temp file (not an in-memory `Data` buffer). `expectedTotal`
    /// seeds progress when the server omits `Content-Length` — typically the
    /// listing's `#length` property.
    func downloadFile(
        username: String,
        path: String,
        expectedTotal: Int64,
        onProgress: NetworkClient.TransferProgressHandler?
    ) async throws -> (tempURL: URL, filename: String) {
        let relative = try relativePath(path, username: username)
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(relative))"
        let filename = URL(fileURLWithPath: (relative as NSString).lastPathComponent).lastPathComponent
        do {
            let (location, _) = try await network.downloadFile(
                urlString,
                timeout: 300,
                expectedTotal: expectedTotal,
                onProgress: onProgress
            )
            // URLSession's download location is ephemeral — move it under a
            // stable name in our temp directory before the system reaps it.
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.moveItem(at: location, to: tempURL)
            return (tempURL, filename)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VOSpaceError.operationFailed("Download failed: \(error.localizedDescription)")
        }
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
        let relative = try relativePath(path, username: username)
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(relative))"
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

    /// Protocol / agent-facing entry — no progress. The Storage UI uses the
    /// overload below so large FITS uploads can drive a determinate bar.
    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
        try await uploadFile(username: username, remotePath: remotePath, fileURL: fileURL, onProgress: nil)
    }

    func uploadFile(
        username: String,
        remotePath: String,
        fileURL: URL,
        onProgress: NetworkClient.TransferProgressHandler?
    ) async throws {
        let relative = try relativePath(remotePath, username: username)
        let urlString = "\(filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(relative))"

        // Sandbox: the source file came from an NSOpenPanel pick by the user,
        // possibly in an earlier transaction. Re-grant access for the read
        // window. The pair is a no-op for files the sandbox already trusts
        // (e.g., temp dir), so it's safe to apply universally.
        let didStart = fileURL.startAccessingSecurityScopedResource()
        defer { if didStart { fileURL.stopAccessingSecurityScopedResource() } }

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
            ?? 0

        do {
            // Small files: in-memory PUT so CADC gets a real Content-Length
            // body (same shape as `upload_text_to_vospace`). `upload(fromFile:)`
            // on a sandbox-invisible URL was creating 0-byte nodes.
            let smallFileCap: Int64 = 32 * 1024 * 1024
            if fileSize > 0, fileSize <= smallFileCap {
                let data = try Data(contentsOf: fileURL)
                guard !data.isEmpty else {
                    throw VOSpaceError.operationFailed("Upload failed: local file is empty")
                }
                _ = try await network.put(
                    urlString,
                    body: data,
                    contentType: "application/octet-stream",
                    timeout: 300
                )
            } else {
                _ = try await network.putFile(
                    urlString,
                    fileURL: fileURL,
                    contentType: "application/octet-stream",
                    timeout: 300,
                    onProgress: onProgress
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VOSpaceError.operationFailed("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Folder

    func createFolder(username: String, parentPath: String, folderName: String) async throws {
        let parent = try relativePath(parentPath, username: username)
        let fullPath = parent.isEmpty ? "\(username)/\(folderName)" : "\(username)/\(parent)/\(folderName)"
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

    // MARK: - ACL (sharing)

    /// Update a node's sharing properties via VOSpace setNode. Three-valued
    /// per dimension: `nil` = leave unchanged, `[]` = revoke all groups,
    /// values = replace the whole list. Groups are full GMS URIs
    /// (`ivo://cadc.nrc.ca/gms?Name`). Wire protocol matches the Windows
    /// client: GET the node first (setNode must echo the existing type and
    /// cannot change it; also confirms existence), then POST the setNode
    /// document to the same URL.
    func setNodeACL(
        username: String,
        path: String,
        groupRead: [String]?,
        groupWrite: [String]?,
        isPublic: Bool?
    ) async throws {
        let relative = try relativePath(path, username: username)
        let fullPath = relative.isEmpty ? username : "\(username)/\(relative)"
        let urlString = "\(nodesBase)/\(Self.encodePath(fullPath))"

        let (data, _) = try await network.get("\(urlString)?detail=min", accept: "text/xml")
        guard let currentXML = String(data: data, encoding: .utf8) else {
            throw VOSpaceError.invalidResponse
        }
        let nodeType = VOSpaceXMLParser.parseRootNodeType(currentXML)

        let xml = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "\(Self.vosPrefix)/\(fullPath)",
            nodeType: nodeType,
            groupRead: groupRead,
            groupWrite: groupWrite,
            isPublic: isPublic
        )
        guard let body = xml.data(using: .utf8) else {
            throw VOSpaceError.operationFailed("Could not encode ACL XML")
        }
        do {
            _ = try await network.post(urlString, body: body, contentType: "text/xml")
        } catch {
            throw VOSpaceError.operationFailed("Set ACL failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete

    /// Hard cap on nodes touched in one recursive delete (UI + MCP).
    /// Bounds catastrophic misclicks while covering typical cleanups
    /// (`__pycache__`, small project trees). Retry the same path to continue.
    static let recursiveDeleteCap: Int = 100

    /// Progress for recursive deletes: `deletedCount` so far, `path` just removed.
    typealias DeleteProgressHandler = @Sendable (_ deletedCount: Int, _ path: String) -> Void

    /// Delete a single node. For non-empty folders use `recursive: true`
    /// (VOSpace refuses DELETE on containers that still have children).
    @discardableResult
    func deleteNode(
        username: String,
        path: String,
        recursive: Bool = false,
        onProgress: DeleteProgressHandler? = nil
    ) async throws -> Int {
        if recursive {
            return try await deleteRecursive(
                username: username,
                path: path,
                runningCount: 0,
                onProgress: onProgress
            )
        }
        try await deleteNodeOnce(username: username, path: path)
        onProgress?(1, path)
        return 1
    }

    /// One-shot HTTP DELETE — used by the recursive walker and by file deletes.
    private func deleteNodeOnce(username: String, path: String) async throws {
        let relative = try relativePath(path, username: username)
        let urlString = "\(nodesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(relative))"
        do {
            let response = try await network.delete(urlString)
            guard (200...299).contains(response.statusCode) else {
                throw Self.mapDeleteHTTPError(status: response.statusCode, path: path)
            }
        } catch let error as VOSpaceError {
            throw error
        } catch let error as NetworkError {
            if case .httpError(let code, _) = error {
                throw Self.mapDeleteHTTPError(status: code, path: path)
            }
            throw VOSpaceError.operationFailed("Delete failed: \(error.localizedDescription)")
        } catch {
            throw VOSpaceError.operationFailed("Delete failed: \(error.localizedDescription)")
        }
    }

    /// Post-order walk: empty each container, then delete it. Listing failure
    /// is treated as “leaf” (file or empty) so we don't add a type probe per node.
    private func deleteRecursive(
        username: String,
        path: String,
        runningCount: Int,
        onProgress: DeleteProgressHandler?
    ) async throws -> Int {
        try Task.checkCancellation()
        var count = runningCount
        let children: [VOSpaceNode] = (try? await listNodes(
            username: username, path: path, limit: 500
        )) ?? []
        for child in children {
            count = try await deleteRecursive(
                username: username,
                path: child.path,
                runningCount: count,
                onProgress: onProgress
            )
        }
        if count >= Self.recursiveDeleteCap {
            throw VOSpaceError.recursiveDeleteCapExceeded(
                deleted: count,
                path: path
            )
        }
        try await deleteNodeOnce(username: username, path: path)
        count += 1
        onProgress?(count, path)
        return count
    }

    private static func mapDeleteHTTPError(status: Int, path: String) -> VOSpaceError {
        switch status {
        case 403:
            return .operationFailed(
                String(format: String(localized: "Permission denied deleting %@"), path)
            )
        case 404:
            return .operationFailed(
                String(format: String(localized: "Not found: %@"), path)
            )
        case 409, 412:
            // ARC commonly refuses DELETE on non-empty containers.
            return .operationFailed(
                String(
                    format: String(localized: "Folder is not empty: %@. Try deleting again to remove contents first."),
                    path
                )
            )
        default:
            return .operationFailed("Delete failed (HTTP \(status))")
        }
    }
}

// MARK: - Errors

enum VOSpaceError: LocalizedError, Equatable {
    case invalidResponse
    case invalidPath
    case operationFailed(String)
    /// Recursive walk hit the safety cap; `deleted` nodes are already gone.
    case recursiveDeleteCapExceeded(deleted: Int, path: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid VOSpace response"
        case .invalidPath: return "Invalid path"
        case .operationFailed(let msg): return msg
        case .recursiveDeleteCapExceeded(let deleted, let path):
            return String(
                format: String(localized: "Folder delete stopped after %lld items (safety limit of %lld). Retry to continue from “%@”."),
                deleted,
                Int64(VOSpaceBrowserService.recursiveDeleteCap),
                path
            )
        }
    }
}
