// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Where a Research file is, at a glance: a laptop for this Mac and a cloud
/// for the person's storage, each lit where the file is (the person's
/// request, 2026-10-09).
struct FilePlacesBadge: View {
    let places: FilePlaces
    /// The file it is of, for the tools: "Where 745234p.fits is: …".
    var file: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(places.onMac ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            Image(systemName: places.inStorage ? "cloud.fill" : "cloud")
                .foregroundStyle(places.inStorage ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        }
        .font(.caption)
        .help(Text(places.title))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.map { Text("Where \($0) is: \(places.title)") } ?? Text(places.title))
        .accessibilityAddTraits(.isImage)
    }
}

/// A record's files, wherever each is (plan 34 F; the person's request,
/// 2026-10-09): its name, its paths and where it is. What is done with them
/// is the record's buttons and Move To… (plan 46): "badges only highlite
/// some state/info", the person said.
struct ResearchFilesSection: View {
    let observation: DownloadedObservation
    var model: ResearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.subheadline.bold())
            ForEach(observation.allFiles) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.places.onMac {
                            Text(DownloadsFolder.displayPath(file.localPath))
                                .font(.caption)
                                .foregroundStyle(file.local.exists ? Color.secondary : Color.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let path = file.storagePath {
                            Label(path, systemImage: "cloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let size = file.size {
                        Text(SharedFormatters.bytes(size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Where it is, not a control: the record's buttons, and
                    // Move To…, act on its files (plan 46).
                    FilePlacesBadge(places: file.places, file: file.name)
                }
            }
        }
    }
}
