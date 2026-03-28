// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

final class StorageService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Fetches storage quota for a user from VOSpace.
    func getQuota(username: String) async throws -> StorageQuota {
        let (data, _) = try await network.get(
            endpoints.storageURL(username),
            accept: "text/xml"
        )

        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidXML
        }

        return try parseVOSpaceXML(xmlString)
    }

    /// Parses VOSpace XML to extract quota and usage.
    private func parseVOSpaceXML(_ xmlString: String) throws -> StorageQuota {
        guard let xmlData = xmlString.data(using: .utf8) else {
            throw StorageError.invalidXML
        }

        let doc = try XMLDocument(data: xmlData)

        var quotaBytes: Int64 = 0
        var usedBytes: Int64 = 0
        var lastModified: String?

        // Find all <property> elements
        let properties = try doc.nodes(forXPath: "//*[local-name()='property']")

        for node in properties {
            guard let element = node as? XMLElement,
                  let uri = element.attribute(forName: "uri")?.stringValue,
                  let value = element.stringValue else {
                continue
            }

            if uri.contains("core#quota") {
                quotaBytes = Int64(value) ?? 0
            } else if uri.contains("core#length") {
                usedBytes = Int64(value) ?? 0
            } else if uri.contains("core#date") {
                lastModified = value
            }
        }

        return StorageQuota(
            quotaBytes: quotaBytes,
            usedBytes: usedBytes,
            lastModified: lastModified
        )
    }
}

enum StorageError: LocalizedError {
    case invalidXML

    var errorDescription: String? {
        switch self {
        case .invalidXML: return "Failed to parse storage information"
        }
    }
}
