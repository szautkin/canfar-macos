// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct NotebookRecoverySheet: View {
    @Binding var isPresented: Bool
    @Binding var recoverableFiles: [(url: URL, name: String, date: Date)]
    var tabHost: NotebookTabHostModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Recover Unsaved Notebooks?")
                .font(.headline)

            Text("The following notebooks were not saved before the app closed:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(recoverableFiles.enumerated()), id: \.offset) { idx, file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.caption.bold())
                                Text(formatDate(file.date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recover") {
                                recoverFile(at: idx)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Discard") {
                                discardFile(at: idx)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button("Recover All") {
                    for i in (0..<recoverableFiles.count).reversed() {
                        recoverFile(at: i)
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Discard All") {
                    AutoSaveService.discardAll()
                    recoverableFiles = []
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 450)
    }

    private func recoverFile(at index: Int) {
        guard index < recoverableFiles.count else { return }
        let file = recoverableFiles[index]
        do {
            let model = NotebookModel()
            try model.openFile(url: file.url)
            model.isDirty = true
            model.filePath = nil // forces Save As
            tabHost.tabs.append(model)
            tabHost.activeTabIndex = tabHost.tabs.count - 1
            try? FileManager.default.removeItem(at: file.url)
        } catch {
            // Silently skip — file may be corrupt
        }
        recoverableFiles.remove(at: index)
        if recoverableFiles.isEmpty { isPresented = false }
    }

    private func discardFile(at index: Int) {
        guard index < recoverableFiles.count else { return }
        try? FileManager.default.removeItem(at: recoverableFiles[index].url)
        recoverableFiles.remove(at: index)
        if recoverableFiles.isEmpty { isPresented = false }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f.string(from: date)
    }
}
