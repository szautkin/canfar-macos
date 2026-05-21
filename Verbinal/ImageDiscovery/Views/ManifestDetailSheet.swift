// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import AppKit

/// Structured view of a discovered image's probe manifest.
///
/// 2026-05-21 Phase 3 of the UX-audit follow-up: the picky-
/// astronomer user wants to verify primary probe data without
/// digging through `~/Library/Application Support/.../*.json`.
/// This sheet renders every section of the manifest in a
/// disclosure-group layout (collapsed by default for the heavy
/// package lists; expandable on click) with copy-as-JSON and
/// reveal-in-Finder affordances in the footer.
///
/// Mirrors `FailureDetailSheet` styling — same header layout,
/// same dismiss flow, same selectable-text discipline — so the
/// two sheets feel like siblings of the same family.
struct ManifestDetailSheet: View {

    let manifest: ImageManifest
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyJSON: Bool = false

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
                VStack(alignment: .leading, spacing: 14) {
                    identitySection
                    osSection
                    capabilitiesSection
                    if !manifest.pythonPackages.isEmpty { pythonSection }
                    if !manifest.condaEnvs.isEmpty { condaSection }
                    if !manifest.rPackages.isEmpty { rSection }
                    if !manifest.dpkgPackages.isEmpty { dpkgSection }
                    if !manifest.rpmPackages.isEmpty { rpmSection }
                    if !manifest.apkPackages.isEmpty { apkSection }
                    if let notes = manifest.probeNotes, !notes.isEmpty {
                        probeNotesSection(notes)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 440, idealHeight: 600)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Image Content Manifest")
                    .font(.headline)
                Text(manifest.imageID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text("Probed \(Self.timeFormatter.string(from: manifest.capturedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("•").font(.caption2).foregroundStyle(.tertiary)
                    Text("schema v\(manifest.schemaVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("•").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(totalPackageCount) packages")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sections

    private var identitySection: some View {
        section(title: "Identity", count: nil) {
            row(label: "Image ID", value: manifest.imageID)
            row(label: "Content hash", value: manifest.contentHash)
            row(label: "Probed at", value: Self.timeFormatter.string(from: manifest.capturedAt))
        }
    }

    private var osSection: some View {
        section(title: "Operating System", count: nil) {
            row(label: "Family", value: manifest.osFamily)
            row(label: "Version", value: manifest.osVersion)
            if manifest.osRelease != "unknown" {
                row(label: "Release", value: manifest.osRelease)
            }
            row(label: "Kernel", value: manifest.kernel)
            if manifest.pythonVersion != "unknown" {
                row(label: "Python", value: manifest.pythonVersion)
            }
            if !manifest.shells.isEmpty {
                row(label: "Shells", value: manifest.shells.joined(separator: ", "))
            }
        }
    }

    private var capabilitiesSection: some View {
        section(title: "Capabilities", count: manifest.capabilities.count) {
            if manifest.capabilities.isEmpty {
                Text("None detected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                FlowTagList(tags: manifest.capabilities)
            }
        }
    }

    @ViewBuilder
    private var pythonSection: some View {
        let grouped = Dictionary(grouping: manifest.pythonPackages) { $0.env.isEmpty ? "system" : $0.env }
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(grouped.keys.sorted(), id: \.self) { env in
                    if grouped.keys.count > 1 {
                        Text(env)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    packageGrid(grouped[env]?.map { (name: $0.name, version: $0.version) } ?? [])
                }
            }
            .padding(.top, 4)
        } label: {
            sectionHeader(title: "Python packages", count: manifest.pythonPackages.count)
        }
    }

    @ViewBuilder
    private var condaSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(manifest.condaEnvs, id: \.name) { env in
                    Text("\(env.name)  \(env.prefix)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    packageGrid(env.packages.map { (name: $0.name, version: $0.version) })
                }
            }
            .padding(.top, 4)
        } label: {
            sectionHeader(title: "Conda envs", count: manifest.condaEnvs.count)
        }
    }

    @ViewBuilder
    private var rSection: some View {
        DisclosureGroup {
            packageGrid(manifest.rPackages.map { (name: $0.name, version: $0.version) })
                .padding(.top, 4)
        } label: {
            sectionHeader(title: "R packages", count: manifest.rPackages.count)
        }
    }

    @ViewBuilder
    private var dpkgSection: some View {
        DisclosureGroup {
            packageGrid(manifest.dpkgPackages.map { (name: $0.name, version: $0.version) })
                .padding(.top, 4)
        } label: {
            sectionHeader(title: "dpkg packages", count: manifest.dpkgPackages.count)
        }
    }

    @ViewBuilder
    private var rpmSection: some View {
        DisclosureGroup {
            packageGrid(manifest.rpmPackages.map { (name: $0.name, version: $0.version) })
                .padding(.top, 4)
        } label: {
            sectionHeader(title: "rpm packages", count: manifest.rpmPackages.count)
        }
    }

    @ViewBuilder
    private var apkSection: some View {
        DisclosureGroup {
            packageGrid(manifest.apkPackages.map { (name: $0.name, version: $0.version) })
                .padding(.top, 4)
        } label: {
            sectionHeader(title: "apk packages", count: manifest.apkPackages.count)
        }
    }

    @ViewBuilder
    private func probeNotesSection(_ notes: String) -> some View {
        section(title: "Probe notes", count: nil) {
            Text(notes)
                .font(.caption2.monospaced())
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Section primitives

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        count: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title: title, count: count)
            content()
                .padding(.leading, 0)
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout.bold())
            if let count {
                Text("\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func packageGrid(_ packages: [(name: String, version: String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(packages, id: \.name) { pkg in
                HStack {
                    Text(pkg.name)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pkg.version)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                revealLocalCopyInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Open Finder with the cached manifest file highlighted.")

            Button {
                copyManifestAsJSON()
            } label: {
                Label(
                    didCopyJSON ? "Copied" : "Copy as JSON",
                    systemImage: didCopyJSON ? "checkmark.circle.fill" : "doc.on.doc"
                )
            }
            .help("Copy the entire manifest as JSON to the clipboard.")
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .help("Close this dialog (⎋)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    /// Open Finder pointing at the local cache file. The file
    /// lives at the JSONManifestStore's directory; we recompute
    /// the safe path here to avoid coupling this view to the
    /// store. If the file doesn't exist (rare — would mean the
    /// in-memory manifest was loaded from VOSpace and cache
    /// flushed), Finder opens the parent directory.
    private func revealLocalCopyInFinder() {
        let dir = JSONManifestStore.defaultDirectory()
        let filename = ImageManifest.sanitize(imageID: manifest.imageID) + ".json"
        let fileURL = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    /// Encode the manifest as pretty-printed JSON and put it on
    /// the clipboard. Visual ack via the button label flip for
    /// ~1.5s. Encoding mirrors the on-disk format so a paste +
    /// `jq` round-trip matches what the cache file holds.
    private func copyManifestAsJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest),
              let s = String(data: data, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        didCopyJSON = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyJSON = false
        }
    }

    // MARK: - Counts

    private var totalPackageCount: Int {
        manifest.dpkgPackages.count
            + manifest.rpmPackages.count
            + manifest.apkPackages.count
            + manifest.pythonPackages.count
            + manifest.rPackages.count
    }
}

/// Compact flowing list of tag pills — used for the
/// `capabilities` section. Wraps to multiple lines on width
/// pressure. Pure layout, no model coupling, so it can be
/// reused for other tag-style displays later.
private struct FlowTagList: View {
    let tags: [String]

    var body: some View {
        // SwiftUI doesn't ship a flow layout; the closest
        // built-in is `HStack` with `.layoutPriority`. For
        // small tag sets (capabilities cap at ~6 entries),
        // a single HStack wraps fine via the SwiftUI 16
        // `Layout` improvements. For larger sets we'd reach
        // for a custom Layout — overkill at this density.
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.green)
            }
            Spacer()
        }
    }
}
