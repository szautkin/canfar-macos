// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Fetches and parses IVOA registry documents: the CADC `resource-caps`
/// map (`ivo://` resource ID → capabilities URL) and per-service VOSI
/// capabilities XML. Anonymous requests only — registry documents are
/// public, so no auth token is involved.
///
/// Parsing is deliberately minimal: `resource-caps` is a `#`-commented
/// `key = value` text file, and from capabilities documents we only need
/// each `<capability standardID=…>`'s `<accessURL>` values. Anything the
/// parsers don't understand is skipped rather than treated as an error, so
/// registry-side additions never break the client.
public struct RegistryClient: Sendable {

    /// One `<capability>` element: its standard ID and every `<accessURL>`
    /// found beneath it (nested interface elements are flattened).
    public struct Capability: Equatable, Sendable {
        public let standardID: String
        public let accessURLs: [String]

        public init(standardID: String, accessURLs: [String]) {
            self.standardID = standardID
            self.accessURLs = accessURLs
        }
    }

    /// Every VOSI service publishes its availability endpoint under this
    /// standard ID; stripping the `/availability` suffix from its accessURL
    /// is the uniform way to recover the service root.
    public static let availabilityStandardID = "ivo://ivoa.net/std/VOSI#availability"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Fetching

    public func fetchResourceCaps(from urlString: String, timeout: TimeInterval = RequestTimeout.lookup) async throws -> [String: String] {
        let data = try await fetch(urlString, timeout: timeout)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Self.parseResourceCaps(text)
    }

    public func fetchCapabilities(at urlString: String, timeout: TimeInterval = RequestTimeout.lookup) async throws -> [Capability] {
        let data = try await fetch(urlString, timeout: timeout)
        return Self.parseCapabilities(data)
    }

    private func fetch(_ urlString: String, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Parsing

    /// Parse the `resource-caps` text format: `key = value` lines, `#`
    /// comments and blank lines ignored, whitespace tolerated.
    public static func parseResourceCaps(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    /// Parse a VOSI capabilities document down to the parts the app needs:
    /// each `<capability standardID=…>` and the `<accessURL>` text beneath
    /// it. Malformed XML yields an empty array, never a crash.
    public static func parseCapabilities(_ data: Data) -> [Capability] {
        let delegate = CapabilitiesParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.capabilities
    }

    /// Recover a service's base URL from its capabilities: the VOSI
    /// availability accessURL minus the trailing `/availability`.
    public static func serviceRoot(from capabilities: [Capability]) -> String? {
        guard let availability = accessURL(for: availabilityStandardID, in: capabilities) else {
            return nil
        }
        let trimmed = availability.hasSuffix("/") ? String(availability.dropLast()) : availability
        guard trimmed.hasSuffix("/availability") else { return nil }
        return String(trimmed.dropLast("/availability".count))
    }

    /// First accessURL published for the given standard ID, if any.
    public static func accessURL(for standardID: String, in capabilities: [Capability]) -> String? {
        capabilities.first(where: { $0.standardID == standardID })?.accessURLs.first
    }
}

/// XMLParser delegate that collects `<capability standardID=…>` elements
/// and the text of every `<accessURL>` nested inside them. Element names
/// are matched without namespace prefixes (`vosi:capabilities` and plain
/// `capabilities` both work).
private final class CapabilitiesParserDelegate: NSObject, XMLParserDelegate {
    var capabilities: [RegistryClient.Capability] = []

    private var currentStandardID: String?
    private var currentAccessURLs: [String] = []
    private var accessURLBuffer: String?

    private static func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch Self.localName(elementName) {
        case "capability":
            currentStandardID = attributeDict["standardID"]
            currentAccessURLs = []
        case "accessURL" where currentStandardID != nil:
            accessURLBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if accessURLBuffer != nil {
            accessURLBuffer?.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.localName(elementName) {
        case "accessURL":
            if let url = accessURLBuffer?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                currentAccessURLs.append(url)
            }
            accessURLBuffer = nil
        case "capability":
            if let standardID = currentStandardID {
                capabilities.append(.init(standardID: standardID, accessURLs: currentAccessURLs))
            }
            currentStandardID = nil
            currentAccessURLs = []
        default:
            break
        }
    }
}
