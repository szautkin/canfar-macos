// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Sheet listing pending agent proposals. Apply / Reject per row;
/// errors surface inline next to the row that failed so the user can
/// see why and decide what to do.
struct ProposalStripSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var perRowError: [UUID: String] = [:]
    @State private var inFlight: Set<UUID> = []

    private var proposals: [PendingProposal] {
        appState.agentsService.pendingProposals
    }

    @State private var selectedTab: Tab = .pending

    private enum Tab: String, Hashable {
        case pending, history
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()
            switch selectedTab {
            case .pending: content
            case .history: historyContent
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 360, idealHeight: 480)
        .task {
            // Pull a fresh snapshot when the sheet opens. If nothing's
            // pending, default the user to the History tab so they
            // see what the agent has done recently.
            await appState.agentsService.refreshPending()
            if proposals.isEmpty,
               !appState.agentsService.activityStore.entries.isEmpty {
                selectedTab = .history
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            tabButton("Pending", count: proposals.count, tab: .pending)
            tabButton("History", count: appState.agentsService.activityStore.entries.count, tab: .history)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(_ label: String, count: Int, tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.callout.weight(selectedTab == tab ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }
            .foregroundStyle(selectedTab == tab ? Color.primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.rays")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Proposals")
                    .font(.headline)
                Text("Review and apply changes proposed by AI agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var historyContent: some View {
        let entries = appState.agentsService.activityStore.entries
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No agent activity yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Applied proposals, rejections, and live UI ops the\nagent has performed will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(entries) { entry in
                    historyRow(entry)
                }
            }
            .listStyle(.inset)
        }
    }

    private func historyRow(_ entry: AgentActivityEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: outcomeIcon(entry.outcome))
                .foregroundStyle(outcomeColor(entry.outcome))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label(entry.kind, systemImage: "function")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(entry.originLabel, systemImage: "personalhotspot")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(Self.relativeTime.localizedString(for: entry.timestamp,
                                                             relativeTo: Date()),
                          systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func outcomeIcon(_ o: AgentActivityEntry.Outcome) -> String {
        switch o {
        case .applied:    return "checkmark.circle.fill"
        case .rejected:   return "xmark.circle.fill"
        case .withdrawn:  return "arrow.uturn.backward.circle.fill"
        case .live:       return "wand.and.rays"
        }
    }

    private func outcomeColor(_ o: AgentActivityEntry.Outcome) -> Color {
        switch o {
        case .applied:    return .green
        case .rejected:   return .orange
        case .withdrawn:  return .secondary
        case .live:       return .accentColor
        }
    }

    @ViewBuilder
    private var content: some View {
        if proposals.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No pending proposals.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(proposals) { proposal in
                    row(for: proposal)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(for proposal: PendingProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                kindBadge(proposal.kind)
                Text(proposal.summary)
                    .font(.callout)
                Spacer()
                if inFlight.contains(proposal.id) {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Button("Reject", role: .destructive) {
                            Task { await reject(proposal) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Apply") {
                            Task { await apply(proposal) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 12) {
                Label(proposal.toolName, systemImage: "function")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(originLabel(proposal.origin), systemImage: "personalhotspot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(Self.relativeTime.localizedString(for: proposal.createdAt, relativeTo: Date()),
                      systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let error = perRowError[proposal.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func kindBadge(_ kind: String) -> some View {
        Text(kind)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }

    private func originLabel(_ origin: OperationOrigin) -> String {
        switch origin {
        case .user: return "user"
        case .external(let id): return id
        }
    }

    private var footer: some View {
        HStack {
            Text("\(proposals.count) pending")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Apply runs the underlying operation; Reject discards.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    @MainActor
    private func apply(_ proposal: PendingProposal) async {
        inFlight.insert(proposal.id)
        perRowError.removeValue(forKey: proposal.id)
        defer { inFlight.remove(proposal.id) }
        do {
            try await appState.agentsService.applyProposal(proposal.id)
        } catch ProposalApplyError.noApplierForKind(let kind) {
            perRowError[proposal.id] = "No handler for kind '\(kind)'."
        } catch {
            perRowError[proposal.id] = "Apply failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func reject(_ proposal: PendingProposal) async {
        inFlight.insert(proposal.id)
        defer { inFlight.remove(proposal.id) }
        await appState.agentsService.rejectProposal(proposal.id)
    }

    private static let relativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
#endif
