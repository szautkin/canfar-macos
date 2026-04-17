// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

/// Actor for browsing and managing VOSpace files via the ARC REST API.
actor VOSpaceBrowserService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "VOSpace")
    private let network: NetworkClient

    private static let nodesBase = "https://ws-uv.canfar.net/arc/nodes/home"
    private static let filesBase = "https://ws-uv.canfar.net/arc/files/home"
    private static let vosPrefix = "vos://cadc.nrc.ca~arc/home"

    init(network: NetworkClient) {
        self.network = network
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
        let urlString = "\(Self.nodesBase)/\(basePath)?limit=\(limit)"
        let (data, _) = try await network.get(urlString, accept: "text/xml")
        guard let xml = String(data: data, encoding: .utf8) else {
            throw VOSpaceError.invalidResponse
        }
        return VOSpaceXMLParser.parseNodeList(xml)
    }

    // MARK: - Download

    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String) {
        let urlString = "\(Self.filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(path))"
        let (data, _) = try await network.get(urlString)
        let filename = URL(fileURLWithPath: (path as NSString).lastPathComponent).lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL)
        return (tempURL, filename)
    }

    // MARK: - Upload

    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
        let urlString = "\(Self.filesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(remotePath))"
        let fileData = try Data(contentsOf: fileURL)
        do {
            _ = try await network.put(urlString, body: fileData, contentType: "application/octet-stream", timeout: 300)
        } catch {
            throw VOSpaceError.operationFailed("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Folder

    func createFolder(username: String, parentPath: String, folderName: String) async throws {
        let fullPath = parentPath.isEmpty ? "\(username)/\(folderName)" : "\(username)/\(parentPath)/\(folderName)"
        let nodeURI = "\(Self.vosPrefix)/\(fullPath)"
        let xml = VOSpaceXMLParser.buildContainerNodeXml(nodeURI: nodeURI)

        let urlString = "\(Self.nodesBase)/\(Self.encodePath(fullPath))"
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
        let urlString = "\(Self.nodesBase)/\(Self.encodeSegment(username))/\(Self.encodePath(path))"
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
