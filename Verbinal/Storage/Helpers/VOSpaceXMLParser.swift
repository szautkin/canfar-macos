// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Parses VOSpace XML responses into VOSpaceNode objects.
enum VOSpaceXMLParser {

    // ISO8601DateFormatter is documented thread-safe; the
    // strict-concurrency check can't infer that for a static.
    // Fractional and non-fractional variants are both needed —
    // ARC emits either `…T10:30:45Z` or `…T10:30:45.123Z`.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let fallbackDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
    }()

    /// Parse a VOSpace `#date` / `#mtime` / `#btime` property value.
    static func parseVOSpaceDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = isoFractional.date(from: trimmed) { return d }
        if let d = isoPlain.date(from: trimmed) { return d }
        for formatter in fallbackDateFormatters {
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Parse a VOSpace container listing XML into child nodes.
    static func parseNodeList(_ xml: String) -> [VOSpaceNode] {
        // Scope `<vos:property>` lookups to each `<vos:node>` subtree —
        // a flat `elements(localName: "property", …)` over the whole
        // document made every node share the LAST property of each
        // kind (so size always read 5772, etc.).
        //
        // `parentsScopedTo: "nodes"` restricts matches to the children
        // inside the `<vos:nodes>` list. A container GET returns the
        // folder ITSELF as the document root `<vos:node>`; unscoped, it
        // was parsed as an extra child, so every folder appeared to
        // contain itself ("run_code_test" inside "run_code_test") and
        // clicking that phantom grew the path one duplicate segment per
        // click. Mirrors the Windows client's VoSpaceParser, which
        // iterates `nodesElement.Elements(node)` only.
        let scoped = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml,
            parentsScopedTo: "nodes"
        )

        return scoped.compactMap { entry -> VOSpaceNode? in
            let attributes = entry.parentAttributes
            guard let uri = attributes["uri"], !uri.isEmpty else { return nil }

            let name: String
            if let lastSlash = uri.lastIndex(of: "/") {
                name = String(uri[uri.index(after: lastSlash)...])
            } else {
                name = uri
            }
            let path = extractPath(uri)

            let xsiType = attributes["xsi:type"] ?? attributes["type"] ?? ""
            let type: VOSpaceNodeType
            if xsiType.contains("ContainerNode") {
                type = .container
            } else if xsiType.contains("LinkNode") {
                type = .linkNode
            } else {
                type = .dataNode
            }

            var node = VOSpaceNode(name: name, path: path, type: type)
            applyProperties(to: &node, properties: entry.children)
            return node
        }
    }

    /// Extract relative path from VOSpace URI.
    /// e.g. "vos://cadc.nrc.ca~arc/home/user/folder/file.fits" → "folder/file.fits"
    static func extractPath(_ uri: String) -> String {
        guard let homeRange = uri.range(of: "/home/", options: .caseInsensitive) else { return uri }
        let afterHome = String(uri[homeRange.upperBound...])
        guard let slashIdx = afterHome.firstIndex(of: "/") else { return "" }
        return String(afterHome[afterHome.index(after: slashIdx)...])
    }

    /// Build VOSpace XML for creating a container (folder) node.
    static func buildContainerNodeXml(nodeURI: String) -> String {
        let escaped = nodeURI
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      uri="\(escaped)"
                      xsi:type="vos:ContainerNode">
              <vos:properties/>
              <vos:accepts/>
              <vos:provides/>
              <vos:capabilities/>
              <vos:nodes/>
            </vos:node>
            """
    }

    /// Root node's `xsi:type` from a single-node GET (`?detail=min`).
    /// Defaults to `.container` on parse failure — matching the Windows
    /// client — because the container document form is the stricter one
    /// (cavern accepts its tail on any type, but 400s a container without it).
    static func parseRootNodeType(_ xml: String) -> VOSpaceNodeType {
        guard let tagStart = xml.range(of: "<vos:node") ?? xml.range(of: "<node"),
              let tagEnd = xml.range(of: ">", range: tagStart.upperBound..<xml.endIndex) else {
            return .container
        }
        let tag = xml[tagStart.lowerBound..<tagEnd.upperBound]
        if tag.contains("ContainerNode") { return .container }
        if tag.contains("LinkNode") { return .linkNode }
        if tag.contains("DataNode") { return .dataNode }
        return .container
    }

    /// Build the VOSpace setNode document for an ACL update. Three-valued
    /// per dimension: `nil` emits no property (server leaves it untouched),
    /// `[]` emits an empty property (revoke all), values replace the whole
    /// list (space-joined — the cavern delimiter). `xsi:type` must echo the
    /// node's existing type, and a ContainerNode must carry the
    /// accepts/provides/capabilities/nodes tail or cavern rejects it with
    /// 400 (the same validator quirk `buildContainerNodeXml` satisfies).
    static func buildSetACLNodeXml(
        nodeURI: String,
        nodeType: VOSpaceNodeType,
        groupRead: [String]?,
        groupWrite: [String]?,
        isPublic: Bool?
    ) -> String {
        let escapedURI = escapeXML(nodeURI)
        let type: String
        switch nodeType {
        case .container: type = "vos:ContainerNode"
        case .linkNode: type = "vos:LinkNode"
        case .dataNode: type = "vos:DataNode"
        }

        var props = ""
        if let groupRead {
            props += aclProperty("ivo://ivoa.net/vospace/core#groupread", joinGroups(groupRead))
        }
        if let groupWrite {
            props += aclProperty("ivo://ivoa.net/vospace/core#groupwrite", joinGroups(groupWrite))
        }
        if let isPublic {
            props += aclProperty("ivo://ivoa.net/vospace/core#ispublic", isPublic ? "true" : "false")
        }

        let containerTail = nodeType == .container
            ? "\n  <vos:accepts/>\n  <vos:provides/>\n  <vos:capabilities/>\n  <vos:nodes/>"
            : ""

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      uri="\(escapedURI)"
                      xsi:type="\(type)">
              <vos:properties>\(props)</vos:properties>\(containerTail)
            </vos:node>
            """
    }

    private static func joinGroups(_ groups: [String]) -> String {
        groups.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func aclProperty(_ uri: String, _ value: String) -> String {
        "\n    <vos:property uri=\"\(escapeXML(uri))\">\(escapeXML(value))</vos:property>"
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Private

    private static func applyProperties(
        to node: inout VOSpaceNode,
        properties: [(attributes: [String: String], text: String)]
    ) {
        for prop in properties {
            guard let propURI = prop.attributes["uri"] else { continue }
            let value = prop.text

            if propURI.hasSuffix("#length"), let size = Int64(value) {
                node.sizeBytes = size
            } else if propURI.hasSuffix("#mtime") || propURI.hasSuffix("#date") {
                // Prefer `#mtime` (data modification) when both are present;
                // `#date` is the IVOA lifecycle date ARC still emits widely.
                if propURI.hasSuffix("#mtime") || node.lastModified == nil {
                    if let parsed = parseVOSpaceDate(value) {
                        node.lastModified = parsed
                    }
                }
            } else if propURI.hasSuffix("#btime") {
                // Birth/creation time — only used when no mtime/date arrived.
                if node.lastModified == nil, let parsed = parseVOSpaceDate(value) {
                    node.lastModified = parsed
                }
            } else if propURI.hasSuffix("#type") {
                node.contentType = value
            } else if propURI.hasSuffix("#ispublic") {
                node.isPublic = value.lowercased() == "true"
            }
        }
    }
}
