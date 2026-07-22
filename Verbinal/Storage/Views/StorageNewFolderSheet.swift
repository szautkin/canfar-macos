// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageNewFolderSheet: View {
    var model: StorageBrowserModel
    @Binding var isPresented: Bool
    @State private var folderName = ""
    @FocusState private var nameFieldFocused: Bool

    private var isNameEmpty: Bool {
        folderName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit { createFolder() }
            HStack {
                Button("Cancel") {
                    folderName = ""
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    createFolder()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isNameEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear { nameFieldFocused = true }
    }

    private func createFolder() {
        guard !isNameEmpty else { return }
        Task {
            await model.createFolder(name: folderName)
            folderName = ""
            isPresented = false
        }
    }
}
