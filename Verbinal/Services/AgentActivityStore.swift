// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// Persistent feed of user-meaningful agent activity.
///
/// Backed by `DiskPersistence` so the breadcrumb survives app
/// relaunches — that's the whole point of having this surface
/// (transient os.log audit + in-memory event ring already exist for
/// real-time / diagnostic use). A 200-entry cap keeps the on-disk
/// footprint to a few KB even after sustained use.
///
/// What lands here:
///   * Applied proposals — one entry per `proposalApplied` lifecycle
///     transition. Carries the proposal id so per-row badge popovers
///     can deep-link back to this entry for the "View source" affordance.
///   * Rejected / withdrawn proposals — one entry each, so the user
///     can see "Claude proposed X but I rejected it" a week later.
///   * View-state ops that don't otherwise leave a trail
///     (`set_search_focus`, `open_fits_file`).
///
/// Bodies / payloads are never persisted here — only the metadata that
/// already shows in the proposal strip preview.
@Observable
@MainActor
final class AgentActivityStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "activity")
    private let persistence: DiskPersistence<[AgentActivityEntry]>
    /// Most-recent first — reverse-chronological feed for the UI.
    private(set) var entries: [AgentActivityEntry] = []
    /// Hard cap on retained entries; older ones drop off the back when
    /// new ones land.
    let cap: Int = 200

    init(fileName: String = "agent_activity.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.entries = persistence.read() ?? []
    }

    /// Append a new entry to the front of the feed and trim the tail
    /// to fit `cap`. Persists to disk synchronously.
    func append(_ entry: AgentActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        persistence.write(entries)
    }

    /// Look up a single entry by proposal id. Used by the per-row
    /// attribution popover to surface the source-proposal entry from
    /// the activity feed.
    func entry(forProposal id: UUID) -> AgentActivityEntry? {
        entries.first(where: { $0.proposalID == id })
    }

    /// Flip the most-recent entry for a proposal id to `autoApplied =
    /// true`. The auto-apply path drives this *after* the applier
    /// runs — the applier itself doesn't know whether it was invoked
    /// via a strip click or via the trusted-client hook, so the
    /// service centralizes the decision here.
    func markAutoApplied(forProposal id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.proposalID == id }),
              entries[idx].outcome == .applied,
              !entries[idx].autoApplied else { return }
        let old = entries[idx]
        entries[idx] = AgentActivityEntry(
            id: old.id,
            timestamp: old.timestamp,
            kind: old.kind,
            summary: old.summary,
            originFingerprint: old.originFingerprint,
            originLabel: old.originLabel,
            proposalID: old.proposalID,
            outcome: old.outcome,
            autoApplied: true
        )
        persistence.write(entries)
    }

    /// Wipe the feed. Surfaced from Settings ▸ Agents ▸ "Clear activity
    /// history" so privacy-conscious users can scrub the breadcrumbs
    /// without nuking their downloaded data or saved queries (which
    /// live in their own stores).
    func clear() {
        entries.removeAll()
        persistence.write(entries)
    }
}
