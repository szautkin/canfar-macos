// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Popover anchored to the info-icon button on each row of
/// `HeadlessJobsDetailSheet`. Surfaces every field of the job's
/// metadata in a copyable form so the user can answer "what did
/// this job actually request?" without right-clicking, opening a
/// modal sheet, or hunting through Skaha's web UI.
///
/// 2026-05-19 addition: closes the "no clear icons; right-click
/// is undiscoverable" UX gap on the Background Jobs widget.
/// Design choices (per UX consult):
///   * Form + `.formStyle(.grouped)` for label/value alignment
///     that matches macOS preferences-pane convention.
///   * Every value is `textSelection(.enabled)` so the user can
///     drag-select and copy ids, image tags, ISO timestamps
///     without a per-field Copy button cluttering the layout.
///   * Fixed width 320pt matches the parent sheet's column
///     density; height adaptive — short on terminated jobs,
///     longer when timing fields are populated.
///   * No auto-close on job state change: a popover dismissing
///     mid-read is disorienting. Dismiss happens on explicit
///     click-outside or ⎋.
struct HeadlessJobInfoPopover: View {

    let job: HeadlessJob

    var body: some View {
        Form {
            Section {
                row(label: "Job ID", value: job.id)
                row(label: "Name", value: job.name)
                row(label: "Type", value: "headless")
            } header: {
                Text("Identity")
            }

            Section {
                row(label: "Image", value: job.image)
                row(label: "Status", value: SessionDisplay.localizedStatus(job.status))
            } header: {
                Text("Container")
            }

            Section {
                row(label: "CPU", value: formattedCPU)
                row(label: "Memory", value: formattedMemory)
                row(label: "GPU", value: formattedGPU)
            } header: {
                Text("Resources Requested")
            } footer: {
                Text("As allocated by Skaha. The job's actual runtime usage may be lower.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                row(label: "Started", value: formattedStarted)
                row(label: "Expires", value: formattedExpires)
            } header: {
                Text("Timing")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .frame(idealHeight: 460)
    }

    // MARK: - Row template

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Field formatting (instance shortcuts)

    private var formattedCPU: String { Self.formatCPU(job.cpuAllocated) }
    private var formattedMemory: String { Self.formatMemory(job.memoryAllocated) }
    private var formattedGPU: String { Self.formatGPU(job.gpuAllocated) }
    private var formattedStarted: String { Self.formatTime(job.startedTime) }
    private var formattedExpires: String { Self.formatTime(job.expiresTime) }

    // MARK: - Pure formatters (internal for unit testing)

    /// Skaha returns CPU allocation as a bare integer string like
    /// `"2"`. Append "core" / "cores" so the value is unambiguous
    /// when read in isolation. Empty → en dash.
    static func formatCPU(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        let plural = raw == "1" ? "core" : "cores"
        return "\(raw) \(plural)"
    }

    /// Format the memory allocation string for display. Skaha
    /// round-trips the requested value through Kubernetes and
    /// back, which means a clean `ram=1` request often surfaces
    /// as `"1.07Gi"` on the response side (1 GiB binary ≈ 1.073
    /// GB decimal — the precision noise leaks through every
    /// unit conversion). The user requested an integer GB and
    /// should see an integer GB — round the numeric prefix to
    /// the nearest whole unit and preserve any K8s suffix
    /// (`Gi`, `Mi`, `G`, `M`, `Ti`, etc.) verbatim.
    ///
    /// Examples:
    ///   * `""` → `"—"`
    ///   * `"1.07Gi"` → `"1Gi"`
    ///   * `"4.29Gi"` → `"4Gi"`
    ///   * `"512Mi"` → `"512Mi"`
    ///   * `"1"` → `"1"`
    ///   * `"weird-format"` → `"weird-format"` (defensive
    ///     passthrough — better to show the raw string than
    ///     to silently drop the field).
    static func formatMemory(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        // Split the leading numeric prefix from any trailing
        // unit suffix. The prefix is at most one decimal
        // (`1.07`), the suffix is alphabetic (`Gi`, `Mi`, `G`,
        // …) or absent. Defensive: any deviation falls
        // through to verbatim passthrough.
        var splitIdx = raw.startIndex
        while splitIdx < raw.endIndex {
            let ch = raw[splitIdx]
            if ch.isNumber || ch == "." {
                splitIdx = raw.index(after: splitIdx)
            } else {
                break
            }
        }
        let numericPart = raw[..<splitIdx]
        let suffix = raw[splitIdx...]
        guard let value = Double(numericPart) else {
            return raw  // entirely non-numeric, echo it
        }
        let rounded = Int(value.rounded())
        return "\(rounded)\(suffix)"
    }

    /// GPU is returned as bare integer; absent or "0" surfaces as
    /// "None" for readability — the user shouldn't have to know
    /// "0" means none in this context.
    static func formatGPU(_ raw: String) -> String {
        if raw.isEmpty || raw == "0" {
            return "None"
        }
        let plural = raw == "1" ? "GPU" : "GPUs"
        return "\(raw) \(plural)"
    }

    /// Render an ISO8601 timestamp as `"MMM d, yyyy HH:mm"`.
    /// Empty input → en dash. Unparseable input → echoes the raw
    /// string (defensive: better to show "weird-format-string"
    /// than to silently drop information when Skaha changes its
    /// format).
    ///
    /// Intentionally separate from `HeadlessJobsDetailSheet`'s
    /// `formatTime`: the row wants compact `"MMM d, HH:mm"`, the
    /// popover wants verbose `"MMM d, yyyy HH:mm"`.
    static func formatTime(_ isoString: String) -> String {
        guard !isoString.isEmpty else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: isoString) {
            return displayFormatter.string(from: date)
        }
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: isoString) {
            return displayFormatter.string(from: date)
        }
        return isoString
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f
    }()
}
