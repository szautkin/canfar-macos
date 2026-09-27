// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A small XML document as a tree of elements, by local name — for
/// answers that are documents rather than tables (a DataLink service
/// descriptor). Built with `XMLParser`, so it works on every platform;
/// external entities are never resolved (the answer comes off the network).
public struct XMLTreeElement: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public var children: [XMLTreeElement]
    public var text: String

    public func attribute(_ name: String) -> String? { attributes[name] }

    /// Direct children called `name`.
    public func elements(_ name: String) -> [XMLTreeElement] { children.filter { $0.name == name } }

    /// Every element below this one, depth first.
    public var descendants: [XMLTreeElement] { children.flatMap { [$0] + $0.descendants } }

    public enum Failure: Error, Equatable {
        case notWellFormed(String)
    }

    public static func parse(_ data: Data) throws(Failure) -> XMLTreeElement {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw .notWellFormed(parser.parserError?.localizedDescription ?? "no root element")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLTreeElement] = []
        var root: XMLTreeElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(XMLTreeElement(name: elementName, attributes: attributeDict, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
        }
    }
}
