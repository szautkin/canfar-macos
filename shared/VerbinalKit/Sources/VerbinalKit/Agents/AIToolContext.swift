// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a tool gets when it's invoked. Keeps tools testable: instead of
/// reaching into singletons, every dependency arrives here, so unit
/// tests inject in-memory or stub implementations.
public struct AIToolContext: Sendable {
    /// Origin classification — drives the budget bucket and audit tag.
    public let origin: OperationOrigin
    /// Stable per-call id. Surfaces in audit logs and proposal records.
    public let requestID: UUID
    /// Proposal queue; tools that mutate state enqueue here.
    public let proposals: any ProposalStore
    /// Budget gate; the router consults this — tools usually don't.
    public let budget: ProposalBudget
    /// Append-only event log used by `list_events`. Optional because not
    /// every test stub wires it — tools that need it should fail
    /// gracefully when absent.
    public let eventLog: EventLog?

    public init(
        origin: OperationOrigin,
        requestID: UUID = UUID(),
        proposals: any ProposalStore,
        budget: ProposalBudget,
        eventLog: EventLog? = nil
    ) {
        self.origin = origin
        self.requestID = requestID
        self.proposals = proposals
        self.budget = budget
        self.eventLog = eventLog
    }
}
