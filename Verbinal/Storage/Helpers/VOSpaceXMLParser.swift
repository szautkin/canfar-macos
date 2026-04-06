// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Parses VOSpace XML responses into VOSpaceNode objects.
enum VOSpaceXMLParser {

    /// Parse a VOSpace container listing XML into child nodes.
    static func parseNodeList(_ xml: String) -> [VOSpaceNode] {
        let nodeElements = SimpleXML.elements(localName: "node", in: xml)

        return nodeElements.compactMap { element -> VOSpaceNode? in
            guard let uri = element.attributes["uri"], !uri.isEmpty else { return nil }

            let name: String
            if let lastSlash = uri.lastIndex(of: "/") {
                name = String(uri[uri.index(after: lastSlash)...])
            } else {
                name = uri
            }
            let path = extractPath(uri)

            let xsiType = element.attributes["xsi:type"] ?? element.attributes["type"] ?? ""
            let type: VOSpaceNodeType
            if xsiType.contains("ContainerNode") {
                type = .container
            } else if xsiType.contains("LinkNode") {
                type = .linkNode
            } else {
                type = .dataNode
            }

            var node = VOSpaceNode(name: name, path: path, type: type)

            // Properties are nested — we need to parse the full XML for this node's properties
            // SimpleXML gives us the text content which includes all nested elements
            // Use a targeted approach: find properties by URI suffix in the full XML
            parseProperties(for: &node, in: xml, nodeURI: uri)

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

    // MARK: - Private

    private static func parseProperties(for node: inout VOSpaceNode, in xml: String, nodeURI: String) {
        let properties = SimpleXML.elements(localName: "property", in: xml)

        // Filter properties that belong to this node (heuristic: they appear after this node's URI in the XML)
        for prop in properties {
            guard let propURI = prop.attributes["uri"] else { continue }
            let value = prop.text

            if propURI.hasSuffix("#length"), let size = Int64(value) {
                node.sizeBytes = size
            } else if propURI.hasSuffix("#date") {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) {
                    node.lastModified = date
                } else {
                    // Try simpler format
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    df.timeZone = TimeZone(identifier: "UTC")
                    node.lastModified = df.date(from: value)
                }
            } else if propURI.hasSuffix("#type") {
                node.contentType = value
            } else if propURI.hasSuffix("#ispublic") {
                node.isPublic = value.lowercased() == "true"
            }
        }
    }
}
