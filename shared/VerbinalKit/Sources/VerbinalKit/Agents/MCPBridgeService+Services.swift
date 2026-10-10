// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension MCPBridgeService {
    // MARK: - Per-connection capability bag

    /// The bridge needs concrete proposal/budget instances per connection.
    /// Subclassing the actor for tests would be awkward; instead, the
    /// caller injects them through `init(router:identity:services:approval:)`,
    /// so the bridge can never be served in an unconfigured state.
    public struct PerConnectionServices: Sendable {
        public let proposals: any ProposalStore
        public let budget: ProposalBudget
        public let eventLog: EventLog?
        /// Where this session's log is kept (plan 23); nil keeps none.
        public let recorder: (any AgentSessionRecorder)?
        /// Whether the person has allowed the session (plan 25); nil lets
        /// every call through.
        public let gate: (any AgentSessionGate)?
        /// Which session a relay's reconnection continues (plan 34 S); nil
        /// makes every connection a new session.
        public let continuity: (any AgentSessionContinuity)?

        public init(proposals: any ProposalStore,
                    budget: ProposalBudget,
                    eventLog: EventLog? = nil,
                    recorder: (any AgentSessionRecorder)? = nil,
                    gate: (any AgentSessionGate)? = nil,
                    continuity: (any AgentSessionContinuity)? = nil) {
            self.proposals = proposals
            self.budget = budget
            self.eventLog = eventLog
            self.recorder = recorder
            self.gate = gate
            self.continuity = continuity
        }
    }
}
