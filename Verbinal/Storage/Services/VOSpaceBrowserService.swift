// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

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

    // MARK: - List

    func listNodes(username: String, path: String = "", limit: Int = 500) async throws -> [VOSpaceNode] {
        let basePath = path.isEmpty ? username : "\(username)/\(path)"
        let urlString = "\(Self.nodesBase)/\(basePath)?limit=\(limit)"
        let (data, _) = try await network.get(urlString, accept: "text/xml")
        guard let xml = String(data: data, encoding: .utf8) else {
            throw VOSpaceError.invalidResponse
        }
        return VOSpaceXMLParser.parseNodeList(xml)
    }

    // MARK: - Download

    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String) {
        let urlString = "\(Self.filesBase)/\(username)/\(path)"
        let (data, _) = try await network.get(urlString)
        let filename = (path as NSString).lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL)
        return (tempURL, filename)
    }

    // MARK: - Upload

    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
        let urlString = "\(Self.filesBase)/\(username)/\(remotePath)"
        guard let url = URL(string: urlString) else { throw VOSpaceError.invalidPath }

        let fileData = try Data(contentsOf: fileURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = fileData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        if let token = await network.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VOSpaceError.operationFailed("Upload failed")
        }
    }

    // MARK: - Create Folder

    func createFolder(username: String, parentPath: String, folderName: String) async throws {
        let fullPath = parentPath.isEmpty ? "\(username)/\(folderName)" : "\(username)/\(parentPath)/\(folderName)"
        let nodeURI = "\(Self.vosPrefix)/\(fullPath)"
        let xml = VOSpaceXMLParser.buildContainerNodeXml(nodeURI: nodeURI)

        let urlString = "\(Self.nodesBase)/\(fullPath)"
        guard let url = URL(string: urlString) else { throw VOSpaceError.invalidPath }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = xml.data(using: .utf8)
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")

        if let token = await network.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VOSpaceError.operationFailed("Create folder failed")
        }
    }

    // MARK: - Delete

    func deleteNode(username: String, path: String) async throws {
        let urlString = "\(Self.nodesBase)/\(username)/\(path)"
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
