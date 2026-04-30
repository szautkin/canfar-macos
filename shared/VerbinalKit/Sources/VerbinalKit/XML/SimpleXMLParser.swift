// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Lightweight cross-platform XML text extractor.
/// Uses XMLDocument (macOS) or XMLParser (iOS) under the hood.
public enum SimpleXML {

    /// Extracts text content of elements matching a local name (ignoring namespace).
    /// Returns the first match, or nil.
    public static func textOfFirst(localName: String, in xmlString: String) -> String? {
        textsOf(localName: localName, in: xmlString).first
    }

    /// Extracts all elements matching a local name, returning (attributes, textContent) pairs.
    public static func elements(localName: String, in xmlString: String) -> [(attributes: [String: String], text: String)] {
        guard let data = xmlString.data(using: .utf8) else { return [] }

        #if os(macOS)
        return macOSElements(localName: localName, data: data)
        #else
        return saxElements(localName: localName, data: data)
        #endif
    }

    /// Extracts text content of all elements matching a local name.
    public static func textsOf(localName: String, in xmlString: String) -> [String] {
        elements(localName: localName, in: xmlString).map(\.text)
    }

    /// For each parent matching `parentLocalName`, returns its attributes plus
    /// the descendant elements matching `childLocalName` *scoped to that
    /// parent's subtree*. This is the difference that matters for VOSpace
    /// listings: `elements(localName: "property", in: xml)` returns every
    /// `<property>` in the document, so per-node parsing has to scope itself
    /// here or every node ends up with the same property values.
    ///
    /// Caveats:
    ///   * `parentLocalName` and `childLocalName` must be distinct — passing
    ///     the same name for both is unsupported.
    ///   * Same-name nesting of `childLocalName` (a `<property>` inside a
    ///     `<property>`) is not supported; the iOS SAX path drops outer text
    ///     accumulated past the inner close. The macOS XPath path returns the
    ///     full descendant set in document order with no flattening.
    public static func nestedElements(
        parentLocalName: String,
        childLocalName: String,
        in xmlString: String
    ) -> [(parentAttributes: [String: String], children: [(attributes: [String: String], text: String)])] {
        guard let data = xmlString.data(using: .utf8) else { return [] }
        #if os(macOS)
        return macOSNestedElements(parentLocalName: parentLocalName,
                                   childLocalName: childLocalName,
                                   data: data)
        #else
        return saxNestedElements(parentLocalName: parentLocalName,
                                 childLocalName: childLocalName,
                                 data: data)
        #endif
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
            return (attributes: attributesOf(element), text: element.stringValue ?? "")
        }
    }

    private static func macOSNestedElements(
        parentLocalName: String,
        childLocalName: String,
        data: Data
    ) -> [(parentAttributes: [String: String], children: [(attributes: [String: String], text: String)])] {
        guard let doc = try? XMLDocument(data: data),
              let parents = try? doc.nodes(forXPath: "//*[local-name()='\(parentLocalName)']") else {
            return []
        }
        return parents.compactMap { node in
            guard let parent = node as? XMLElement else { return nil }
            let pAttrs = attributesOf(parent)
            let childNodes = (try? parent.nodes(forXPath: ".//*[local-name()='\(childLocalName)']")) ?? []
            let children: [(attributes: [String: String], text: String)] = childNodes.compactMap {
                guard let el = $0 as? XMLElement else { return nil }
                return (attributes: attributesOf(el), text: el.stringValue ?? "")
            }
            return (parentAttributes: pAttrs, children: children)
        }
    }

    private static func attributesOf(_ element: XMLElement) -> [String: String] {
        var attrs: [String: String] = [:]
        if let attributes = element.attributes {
            for attr in attributes {
                if let name = attr.name, let value = attr.stringValue {
                    attrs[name] = value
                }
            }
        }
        return attrs
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

    private static func saxNestedElements(
        parentLocalName: String,
        childLocalName: String,
        data: Data
    ) -> [(parentAttributes: [String: String], children: [(attributes: [String: String], text: String)])] {
        let delegate = NestedSAXDelegate(parentLocalName: parentLocalName, childLocalName: childLocalName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    private final class NestedSAXDelegate: NSObject, XMLParserDelegate {
        let parentLocalName: String
        let childLocalName: String
        var results: [(parentAttributes: [String: String], children: [(attributes: [String: String], text: String)])] = []
        private var parentDepth = 0
        private var currentParentAttrs: [String: String] = [:]
        private var currentChildren: [(attributes: [String: String], text: String)] = []
        private var inChild = false
        private var currentChildAttrs: [String: String] = [:]
        private var currentChildText = ""

        init(parentLocalName: String, childLocalName: String) {
            self.parentLocalName = parentLocalName
            self.childLocalName = childLocalName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?,
                     attributes: [String: String]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == parentLocalName {
                if parentDepth == 0 {
                    currentParentAttrs = attributes
                    currentChildren = []
                }
                parentDepth += 1
            } else if parentDepth > 0 && local == childLocalName && !inChild {
                inChild = true
                currentChildAttrs = attributes
                currentChildText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inChild { currentChildText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            // `else if` matters: when callers misuse the API by passing the
            // same name for parent and child, this prevents a single closing
            // tag from being consumed as a child end *and* a parent end.
            if local == childLocalName && inChild {
                currentChildren.append((attributes: currentChildAttrs,
                                        text: currentChildText.trimmingCharacters(in: .whitespacesAndNewlines)))
                inChild = false
            } else if local == parentLocalName && parentDepth > 0 {
                parentDepth -= 1
                if parentDepth == 0 {
                    results.append((parentAttributes: currentParentAttrs, children: currentChildren))
                }
            }
        }
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
