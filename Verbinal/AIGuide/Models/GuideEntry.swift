// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the person tells assistants, as the sync carries it (plan 36 3.4):
/// a guide they wrote, their description of one of Verbinal's tools, or
/// their default session instructions. Only what is in force travels — an
/// assistant's proposal waits in Pending on its own device, and approvals
/// and session logs never leave it. Its date is not part of what it says.
struct GuideEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case guide, toolDescription, sessionInstructions
    }

    var kind: Kind
    /// A guide's name, or the tool a description is for; empty for the instructions.
    var name: String
    /// A guide's description, a tool's description, or the instructions.
    var text: String
    /// A guide's body.
    var body: String?
    var modified: Date = .distantPast

    enum CodingKeys: String, CodingKey { case kind, name, text, body }

    /// Its identity across devices: a guide by its name, a description by its tool.
    var key: String { "\(kind.rawValue):\(name)" }

    /// The kind and name a key says; nil for a key this build does not know.
    static func parse(key: String) -> (kind: Kind, name: String)? {
        guard let colon = key.firstIndex(of: ":"), let kind = Kind(rawValue: String(key[..<colon])) else { return nil }
        return (kind, String(key[key.index(after: colon)...]))
    }
}
