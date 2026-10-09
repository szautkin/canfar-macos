// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// "Saving to ~/Downloads — Change…": where a download goes, said where the
/// person downloads (plan 34 F).
struct DownloadFolderLine: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let setting = appState.downloadFolder
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Saving to \(setting.displayPath)")
                .lineLimit(1)
                .truncationMode(.middle)
            if let missing = setting.unavailable {
                Text("(\(missing) is not available)")
                    .foregroundStyle(.orange)
            }
            Spacer()
            #if os(macOS)
            Button("Change…") { setting.chooseWithPanel() }
                .buttonStyle(.link)
                .pointable("downloads.folder.change", opens: "Choose the Download Folder")
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#if os(macOS)
/// Settings ▸ General ▸ Downloads: the download folder (plan 34 F).
struct DownloadFolderSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let setting = appState.downloadFolder
        Section {
            LabeledContent {
                Text(setting.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Label("Download folder", systemImage: "folder")
            }
            if let missing = setting.unavailable {
                Label("\(missing) is not available: downloads go to Downloads until it is back.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Change…") { setting.chooseWithPanel() }
                    .pointable("settings.general.downloadFolder", opens: "Choose the Download Folder")
                Button("Show in Finder") { setting.showInFinder() }
                Spacer()
                Button("Use Downloads") { setting.useDownloads() }
                    .disabled(setting.isDownloads && setting.unavailable == nil)
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Where Verbinal saves what you download — an observation and its files, cutouts, figures, exports — never over another file. Research keeps where each file went.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
