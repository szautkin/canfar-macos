// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os

/// Where the services are now (plan 53 A1): what a service reads on each
/// request, instead of a copy taken when it was made.
public protocol EndpointsSource: Sendable {
    var current: APIEndpoints { get }
}

extension APIEndpoints: EndpointsSource {
    /// A fixed set: for tests, previews and one-off clients.
    public var current: APIEndpoints { self }
}

/// The endpoints in use, replaced when the registry answers or the person
/// overrides one: every service reading it sees the change on its next
/// request, without a relaunch.
public final class LiveEndpoints: EndpointsSource {
    private let value: OSAllocatedUnfairLock<APIEndpoints>

    public init(_ endpoints: APIEndpoints = APIEndpoints()) {
        value = OSAllocatedUnfairLock(initialState: endpoints)
    }

    public var current: APIEndpoints { value.withLock { $0 } }

    public func update(_ endpoints: APIEndpoints) {
        value.withLock { $0 = endpoints }
    }
}
