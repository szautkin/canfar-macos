// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The status bar along the bottom of the window: what the app is doing,
/// in one line, and how many things went wrong. A click opens the list —
/// newest first, each with its stage or its reason — which is where a
/// failure from a sheet closed long ago can still be read.
struct ActivityBar: View {
    var registry: TaskRegistry
    @State private var showList = false

    var body: some View {
        let tasks = registry.tasks
        Button { showList.toggle() } label: {
            HStack(spacing: 8) {
                if registry.runningCount > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                }
                Text(ActivitySummary.line(tasks))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failures = ActivitySummary.failures(tasks) {
                    Text(failures).foregroundStyle(.red)
                }
                Spacer()
                Image(systemName: showList ? "chevron.down" : "chevron.up").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ActivitySummary.line(tasks)))
        .accessibilityHint(Text("Shows what the app is doing and what went wrong"))
        .pointable("activity.bar", label: "Activity", screen: "window")
        .popover(isPresented: $showList, arrowEdge: .top) {
            ActivityList(registry: registry)
        }
    }
}

/// The tasks in full, newest first.
private struct ActivityList: View {
    var registry: TaskRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if registry.tasks.contains(where: \.isFinished) {
                    Button("Clear Finished") { registry.clearFinished() }
                        .controlSize(.small)
                }
            }
            if registry.tasks.isEmpty {
                Text("Nothing has run since Verbinal started.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Redrawn each second while something runs, so its time grows.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(ActivitySummary.lines(registry.tasks, now: context.date).enumerated()), id: \.offset) { _, line in
                                row(line)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        .frame(maxHeight: 420)
    }

    private func row(_ line: ActivitySummary.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(line.progress))
                .foregroundStyle(Self.color(line.progress))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(line.startedBy).font(.caption2).foregroundStyle(.secondary)
                }
                // A failure's reason can be a paragraph — the one thing the
                // list was opened for, so it is never cut.
                Text(line.detail)
                    .font(.caption)
                    .foregroundStyle(line.progress == .running ? .secondary : Self.color(line.progress))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func icon(_ progress: TaskProgress) -> String {
        switch progress {
        case .running: return "stopwatch"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.octagon.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private static func color(_ progress: TaskProgress) -> Color {
        switch progress {
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
