// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Modal sheet that shows the full text of a probe-discovery
/// failure. Exists because:
///
/// 1. The row's inline error label is single-/double-line so it
///    can't render the long Skaha responses (HTTP 500 with a
///    nested K8s 404 body, audit headers, etc.) without wrapping
///    the row out of the layout.
/// 2. `ProbeLogsSheet` is keyed on a Skaha session id, so it
///    can't render failures that exhausted before Skaha returned
///    one (K8s race after retry, network errors, etc.).
///
/// Plain selectable Text inside a ScrollView — the user is
/// expected to copy the message verbatim into a CADC ticket.
struct FailureDetailSheet: View {
    let detail: ImageDiscoveryModel.FailureDetail
    @Environment(\.dismiss) private var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(detail.message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(Color.textFieldBackground)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 360, idealHeight: 480)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Probe Failure Detail")
                    .font(.headline)
                Text(detail.imageID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: detail.attemptedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let jobID = detail.jobID {
                        Text("•").font(.caption2).foregroundStyle(.tertiary)
                        Text("Job \(jobID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                PlatformClipboard.copy(detail.message)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the failure message to the clipboard (⇧⌘C)")
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .help("Close this dialog (⎋)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
