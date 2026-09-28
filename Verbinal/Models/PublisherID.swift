// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A CAOM publisher ID, `ivo://cadc.nrc.ca/COLLECTION?OBSERVATION/PRODUCT`
/// (or its `caom:COLLECTION/OBSERVATION/PRODUCT` form), read into its parts
/// — what an observation is called when nothing else about it is known.
struct PublisherID: Equatable, Sendable {
    let collection: String
    let observationID: String
    let productID: String

    /// Nil for text that is not an `ivo://…/COLLECTION?OBS/PRODUCT` or
    /// `caom:COLLECTION/OBS/PRODUCT` URI.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection: String
        let rest: [String]
        if trimmed.lowercased().hasPrefix("caom:") {
            let parts = trimmed.dropFirst("caom:".count).split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            collection = parts[0]
            rest = Array(parts.dropFirst())
        } else {
            guard trimmed.lowercased().hasPrefix("ivo://"),
                  let query = trimmed.firstIndex(of: "?") else { return nil }
            collection = trimmed[..<query].split(separator: "/").last.map(String.init) ?? ""
            rest = trimmed[trimmed.index(after: query)...].split(separator: "/", maxSplits: 1).map(String.init)
        }
        guard !collection.isEmpty, let observation = rest.first, !observation.isEmpty else { return nil }
        self.collection = collection
        observationID = observation
        productID = rest.count > 1 ? rest[1] : ""
    }

    /// Why `text` is not a publisher ID, the form one takes, and — for the
    /// slash form some tables print, `ivo://cadc.nrc.ca/CFHT/1525350` — the
    /// ID it most likely means.
    static func malformed(_ text: String) -> String {
        var message = "\"\(text)\" is not a publisher ID: one is ivo://cadc.nrc.ca/COLLECTION?OBSERVATION/PRODUCT"
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "ivo",
           url.query == nil, let host = url.host {
            let path = url.path.split(separator: "/").map(String.init)
            if path.count >= 2 {
                let collection = path[path.count - 2], observation = path[path.count - 1]
                let prefix = path.dropLast(2).map { "/\($0)" }.joined()
                message += " — did you mean ivo://\(host)\(prefix)/\(collection)?\(observation)?"
            }
        }
        return message
    }
}
