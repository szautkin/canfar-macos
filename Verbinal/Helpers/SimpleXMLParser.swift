// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Lightweight cross-platform XML text extractor.
/// Uses XMLDocument (macOS) or XMLParser (iOS) under the hood.
enum SimpleXML {

    /// Extracts text content of elements matching a local name (ignoring namespace).
    /// Returns the first match, or nil.
    static func textOfFirst(localName: String, in xmlString: String) -> String? {
        textsOf(localName: localName, in: xmlString).first
    }

    /// Extracts all elements matching a local name, returning (attributes, textContent) pairs.
    static func elements(localName: String, in xmlString: String) -> [(attributes: [String: String], text: String)] {
        guard let data = xmlString.data(using: .utf8) else { return [] }

        #if os(macOS)
        return macOSElements(localName: localName, data: data)
        #else
        return saxElements(localName: localName, data: data)
        #endif
    }

    /// Extracts text content of all elements matching a local name.
    static func textsOf(localName: String, in xmlString: String) -> [String] {
        elements(localName: localName, in: xmlString).map(\.text)
    }

    // MARK: - macOS (XMLDocument / XPath)

    #if os(macOS)
    private static func macOSElements(localName: String, data: Data) -> [(attributes: [String: String], text: String)] {
        guard let doc = try? XMLDocument(data: data),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='\(localName)']") else {
            return []
        }
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            var attrs: [String: String] = [:]
            if let attributes = element.attributes {
                for attr in attributes {
                    if let name = attr.name, let value = attr.stringValue {
                        attrs[name] = value
                    }
                }
            }
            return (attributes: attrs, text: element.stringValue ?? "")
        }
    }
    #endif

    // MARK: - iOS (XMLParser / SAX)

    #if os(iOS)
    private static func saxElements(localName: String, data: Data) -> [(attributes: [String: String], text: String)] {
        let delegate = SAXDelegate(targetLocalName: localName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    private final class SAXDelegate: NSObject, XMLParserDelegate {
        let targetLocalName: String
        var results: [(attributes: [String: String], text: String)] = []
        private var isCollecting = false
        private var currentText = ""
        private var currentAttributes: [String: String] = [:]

        init(targetLocalName: String) {
            self.targetLocalName = targetLocalName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?,
                     attributes: [String: String]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == targetLocalName {
                isCollecting = true
                currentText = ""
                currentAttributes = attributes
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollecting { currentText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == targetLocalName && isCollecting {
                results.append((attributes: currentAttributes, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
                isCollecting = false
            }
        }
    }
    #endif
}
