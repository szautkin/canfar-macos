// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The service a request went to, named once: an id that matches
/// `get_service_health`'s (`cadc-tap`), and a name in words ("the CADC
/// archive search"). The URL is read to name it and not kept — no path,
/// no query (plan 23).
public struct RequestService: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let host: String

    public init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }

    /// The service `url` belongs to. CADC and CANFAR services are known by
    /// their path, whatever host a deployment puts them on; others by a
    /// host registered with `register(host:id:name:)`, or by their host.
    public static func of(_ url: URL?) -> RequestService {
        let host = url?.host?.lowercased() ?? "?"
        if let known = Registry.shared.named(host) {
            return RequestService(id: known.id, name: known.name, host: host)
        }
        let segments = url?.pathComponents.filter { $0 != "/" }.map { $0.lowercased() } ?? []
        let rule = pathRules
            .filter { segments.starts(with: $0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
        guard let rule else { return RequestService(id: host, name: host, host: host) }
        return RequestService(id: rule.id, name: rule.name, host: host)
    }

    /// Names a service reached by its host, not its path: a VizieR mirror,
    /// an image registry.
    public static func register(host: String, id: String, name: String) {
        Registry.shared.add(host.lowercased(), id: id, name: name)
    }

    /// CADC and CANFAR services by the start of their path — data, not
    /// branches: a service added is a row (ETC).
    static let pathRules: [(prefix: [String], id: String, name: String)] = [
        (["ac"], "cadc-auth", "CADC sign-in"),
        (["reg"], "cadc-registry", "the CANFAR registry"),
        (["argus"], "cadc-tap", "the CADC archive search"),
        (["youcat"], "cadc-youcat", "the CADC user tables"),
        (["cadc-target-resolver"], "cadc-resolver", "the CADC target resolver"),
        (["caom2ops"], "cadc-caom2", "the CADC archive details"),
        (["caom2ops", "datalink"], "cadc-datalink", "CADC DataLink"),
        (["caom2ops", "pkg"], "cadc-data", "the CADC archive's files"),
        (["data"], "cadc-data", "the CADC archive's files"),
        (["minoc"], "cadc-data", "the CADC archive's files"),
        (["raven"], "cadc-data", "the CADC archive's files"),
        (["arc"], "vospace", "CANFAR storage"),
        (["vault"], "vospace", "CANFAR storage"),
        (["cavern"], "vospace", "CANFAR storage"),
        (["skaha"], "skaha", "CANFAR sessions"),
    ]

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var hosts: [String: (id: String, name: String)] = [
            "images.canfar.net": ("harbor", "the CANFAR image registry"),
        ]

        func add(_ host: String, id: String, name: String) {
            lock.withLock { hosts[host] = (id, name) }
        }

        func named(_ host: String) -> (id: String, name: String)? {
            lock.withLock { hosts[host] }
        }
    }
}
