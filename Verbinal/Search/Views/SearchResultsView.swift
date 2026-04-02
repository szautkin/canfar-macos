// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SearchResultsView: View {
    var resultsModel: SearchResultsModel
    var tapClient: TAPClient
    var researchModel: ResearchModel?
    @Environment(\.openURL) private var openURL
    @State private var selectedResult: SearchResult?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()

            if resultsModel.results.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Run a search to see results here.")
                )
            } else {
                resultsTable
            }
        }
        .sheet(item: $selectedResult) { result in
            ResultDetailSheet(
                result: result,
                columns: resultsModel.columns,
                tapClient: tapClient,
                researchModel: researchModel
            )
        }
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        HStack {
            if resultsModel.totalRows > 0 {
                if resultsModel.maxRecordReached {
                    Label(
                        "\(resultsModel.totalRows) rows (limit reached)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("\(resultsModel.totalRows) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button("Export CSV") { Task { await exportResults(format: "csv", ext: "csv") } }
                Button("Export TSV") { Task { await exportResults(format: "tsv", ext: "tsv") } }
                Button("Export VOTable") { Task { await exportResults(format: "votable", ext: "xml") } }
            } label: {
                HStack(spacing: 4) {
                    if isExporting { ProgressView().scaleEffect(0.6) }
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
            }
            .disabled(resultsModel.results.isEmpty || isExporting)

            Menu {
                ForEach(resultsModel.columns) { col in
                    Toggle(col.label, isOn: Binding(
                        get: { col.visible },
                        set: { _ in resultsModel.toggleColumnVisibility(col.id) }
                    ))
                }
            } label: {
                Label("Columns", systemImage: "tablecells")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Results Table

    private var resultsTable: some View {
        let visibleCols = resultsModel.visibleColumns

        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(resultsModel.results) { result in
                        resultRow(result, columns: visibleCols)
                    }
                } header: {
                    headerRow(columns: visibleCols)
                }
            }
        }
    }

    private func headerRow(columns: [SearchResultColumn]) -> some View {
        HStack(spacing: 0) {
            // Preview column header
            Text("")
                .frame(width: 30)

            ForEach(columns) { col in
                Text(col.label)
                    .font(.caption.bold())
                    .frame(width: columnWidth(col.id), alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
        .background(.bar)
    }

    private func resultRow(_ result: SearchResult, columns: [SearchResultColumn]) -> some View {
        HStack(spacing: 0) {
            // Preview thumbnail icon — click opens detail
            PreviewThumbnailCell(result: result, tapClient: tapClient) {
                selectedResult = result
            }
            .frame(width: 30)

            // Data columns — click opens detail
            Button {
                selectedResult = result
            } label: {
                HStack(spacing: 0) {
                    ForEach(columns) { col in
                        let raw = result.values[col.id] ?? ""
                        let formatted = CellFormatters.format(key: col.id, raw: raw)
                        Text(formatted)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: columnWidth(col.id), alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func columnWidth(_ key: String) -> CGFloat {
        switch key {
        case "collection": return 80
        case "targetname": return 110
        case "ra(j20000)", "dec(j20000)": return 90
        case "startdate", "enddate": return 90
        case "instrument": return 90
        case "filter", "callev": return 60
        case "obstype", "datatype": return 70
        case "proposalid", "piname": return 100
        case "obsid": return 120
        case "inttime": return 60
        case "band": return 60
        default: return 100
        }
    }

    // MARK: - Export

    private func exportResults(format: String, ext: String) async {
        guard let url = resultsModel.exportURL(format: format) else { return }
        isExporting = true

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                isExporting = false
                return
            }

            let filename = "results.\(ext)"
            let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: stableTemp.path) {
                try FileManager.default.removeItem(at: stableTemp)
            }
            try FileManager.default.moveItem(at: tempURL, to: stableTemp)

            #if os(macOS)
            await presentExportSavePanel(filename: filename, tempURL: stableTemp)
            #endif
        } catch {
            // Silent failure — user can retry
        }

        isExporting = false
    }

    #if os(macOS)
    @MainActor
    private func presentExportSavePanel(filename: String, tempURL: URL) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.title = "Save Results"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.directoryURL = docs

        let response = panel.runModal()
        if response == .OK, let saveURL = panel.url {
            try? moveExport(from: tempURL, to: saveURL)
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func moveExport(from tempURL: URL, to saveURL: URL) throws {
        if FileManager.default.fileExists(atPath: saveURL.path) {
            try FileManager.default.removeItem(at: saveURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: saveURL)
    }
    #endif
}

