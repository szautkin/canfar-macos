// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One session in the Portal, the same on iPhone and iPad: what it is, how
/// long it has left, and what can be done with it. Delete goes through the
/// menu, and the Portal asks before it deletes.
struct iOSSessionRow: View {
    let session: Session
    var isBusy: Bool
    var onOpen: () -> Void
    var onRenew: () -> Void
    var onLogs: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                typeIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(SessionDisplay.shortImageLabel(session.containerImage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(verbatim: SessionDisplay.localizedStatus(session.status))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SessionDisplay.statusColor(session.status).opacity(0.15))
                    .foregroundStyle(SessionDisplay.statusColor(session.status))
                    .clipShape(Capsule())
            }

            TimelineView(.everyMinute) { context in
                timeLine(now: context.date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            resourcesLine
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Icons, large and of one width (the person, 2026-10-22: "remove
            // text from buttons but have them large"); each still says its
            // name to VoiceOver.
            HStack(spacing: 10) {
                Button(action: onOpen) { actionLabel("Open", "safari") }
                    .disabled(!session.isRunning)
                Button(action: onRenew) { actionLabel("Renew", "clock.arrow.circlepath") }
                    .disabled(!session.isRunning)
                Button(action: onLogs) { actionLabel("Logs", "doc.text") }
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete…", systemImage: "trash")
                    }
                } label: {
                    actionLabel("More", "ellipsis")
                }
                .menuStyle(.button)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
        .opacity(isBusy ? 0.4 : 1)
    }

    private func actionLabel(_ title: LocalizedStringKey, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 36)
    }

    private var typeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(SessionDisplay.typeColor(session.sessionType).opacity(0.15))
            if let asset = SessionDisplay.typeImageAsset(session.sessionType) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: SessionDisplay.typeIcon(session.sessionType))
                    .foregroundStyle(SessionDisplay.typeColor(session.sessionType))
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    /// Running: how long it has left, and when it ends. Otherwise: when it started.
    @ViewBuilder
    private func timeLine(now: Date) -> some View {
        if session.isRunning, let end = SessionTimes.date(session.expiresTime) {
            if let left = SessionTimes.remaining(until: end, now: now) {
                Label("Expires in \(left) · \(SessionDisplay.formatTime(session.expiresTime))", systemImage: "timer")
            } else {
                Label("Expired", systemImage: "timer")
            }
        } else {
            Label(SessionDisplay.formatTime(session.startedTime), systemImage: "clock")
        }
    }

    private var resourcesLine: some View {
        HStack(spacing: 12) {
            if !session.cpuAllocated.isEmpty {
                Label("CPU: \(session.cpuAllocated)", systemImage: "cpu")
            }
            if !session.memoryAllocated.isEmpty {
                Label("RAM: \(session.memoryAllocated)", systemImage: "memorychip")
            }
            if !session.gpuAllocated.isEmpty, session.gpuAllocated != "0" {
                Label("GPU: \(session.gpuAllocated)", systemImage: "square.stack.3d.up")
            }
            if !session.isFixedResources {
                Text("FLEX")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
    }
}
