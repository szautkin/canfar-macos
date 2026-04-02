// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ADQLEditorView: View {
    var searchModel: SearchFormModel
    @State private var editableQuery: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                Button {
                    generateFromForm()
                } label: {
                    Label("Generate from Form", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await executeQuery() }
                } label: {
                    HStack(spacing: 4) {
                        if searchModel.isSearching {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text("Execute")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editableQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchModel.isSearching)
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Spacer()

                Button {
                    saveCurrentQuery()
                } label: {
                    Label("Save Query", systemImage: "bookmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(editableQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = searchModel.searchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Query editor — smart quotes and autocorrect disabled for code editing
            ADQLTextEditor(text: $editableQuery)
                .padding(8)
        }
        .onAppear {
            if !searchModel.resultsModel.adqlQuery.isEmpty {
                editableQuery = searchModel.resultsModel.adqlQuery
            }
        }
        .onChange(of: searchModel.resultsModel.adqlQuery) { _, newValue in
            if !newValue.isEmpty {
                editableQuery = newValue
            }
        }
    }

    private func generateFromForm() {
        let resolverCoords: (ra: String, dec: String)?
        if let result = searchModel.resolverResult, !result.coordsRA.isEmpty {
            resolverCoords = (ra: result.coordsRA, dec: result.coordsDec)
        } else {
            resolverCoords = nil
        }
        editableQuery = ADQLBuilder.buildQuery(
            formState: searchModel.formState,
            resolverCoords: resolverCoords
        )
    }

    private func executeQuery() async {
        await searchModel.executeRawQuery(editableQuery)
    }

    private func saveCurrentQuery() {
        let trimmed = editableQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchModel.saveQuery(trimmed)
    }
}
