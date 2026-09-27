// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ADQLEditorView: View {
    var searchModel: SearchFormModel
    @State private var editableQuery: String = ""
    @State private var selectRequest: Range<Int>?

    /// Checked against the cached schema only, so typing never waits on
    /// the network; until the schema arrives only the dialect rules apply.
    private var problems: [ADQLProblem] {
        ADQLValidator.problems(in: editableQuery, schema: searchModel.tapSchema.cached)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                Button {
                    generateFromForm()
                } label: {
                    Label("Generate from Form", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await executeQuery() }
                } label: {
                    HStack(spacing: 4) {
                        if searchModel.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Execute")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(editableQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || searchModel.isSearching || !problems.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help(problems.isEmpty ? "" : String(localized: "Fix the problems listed under the query first"))

                SearchCancelButton(searchModel: searchModel)

                Spacer()

                Button {
                    saveCurrentQuery()
                } label: {
                    Label("Save Query", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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
            ADQLTextEditor(text: $editableQuery, problems: problems.map(\.range), select: $selectRequest)
                .padding(8)

            if !problems.isEmpty {
                Divider()
                problemList
            }
        }
        .task { searchModel.tapSchema.prefetch() }
        // Single source of truth for syncing the upstream adqlQuery into the
        // editor. `initial: true` fires once when the view appears (covering
        // initial population from saved-query loads / form generation that
        // happened before this view was on screen) and on every later change.
        .onChange(of: searchModel.resultsModel.adqlQuery, initial: true) { oldValue, newValue in
            // Initially only a real query is copied in; later an emptied
            // query (set_adql_query with "") clears the editor too.
            if !newValue.isEmpty || oldValue != newValue {
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

    /// What the checker found; a click selects the offending text.
    private var problemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    Button {
                        selectRequest = problem.range
                    } label: {
                        Label(problem.localizedSummary, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Select it in the query")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 120)
    }

    private func executeQuery() async {
        await searchModel.executeRawQuery(editableQuery, fromEditor: true)
    }

    private func saveCurrentQuery() {
        let trimmed = editableQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchModel.saveQuery(trimmed)
    }
}
