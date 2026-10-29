// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Who a relay is (plan 52 A6): its process, the client that launched it,
/// and the Verbinal it was launched from. It goes to the app with the
/// relay's introduction, so the person sees what is connected. It is never
/// told to an assistant.
public struct RelayIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var started: Date
    /// The client that launched it: its process, and its name when the
    /// sandbox lets the relay read it.
    public var parentPID: Int32
    public var parentName: String?
    /// The Verbinal it runs from: "1.4.2", its build, the executable's path.
    public var version: String
    public var build: String?
    public var executable: String

    public init(pid: Int32, started: Date, parentPID: Int32, parentName: String?,
                version: String, build: String?, executable: String) {
        self.pid = pid
        self.started = started
        self.parentPID = parentPID
        self.parentName = parentName
        self.version = version
        self.build = build
        self.executable = executable
    }

    /// As a JSON object, for a frame built with `JSONSerialization`.
    var jsonObject: Any? {
        (try? Self.encoder.encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// From an introduction's `relay` object; nil when it has none, as an
    /// older relay's has not.
    init?(jsonObject: Any?) {
        guard let jsonObject, JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let identity = try? Self.decoder.decode(RelayIdentity.self, from: data) else { return nil }
        self = identity
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
