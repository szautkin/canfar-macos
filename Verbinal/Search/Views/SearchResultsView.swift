// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
#if os(macOS)
import AppKit
#endif

// Architecture note — why a hand-rolled `ScrollView` + `LazyVStack` and not
// SwiftUI `Table`:
//
// Dynamic columns CAN work with native `Table` — the recipe is:
//   • make `SearchResult: Comparable` (trivial id-based),
//   • write a `SortComparator` whose `Compared == SearchResult` and dispatches
//     to `SearchResultsModel.compare` using the column's kind + index,
//   • use `TableColumn(label, value: \SearchResult.self, comparator: ...)`
//     inside `TableColumnForEach`, and bind
//     `sortOrder: Binding<[KeyPathComparator<SearchResult>]>`.
// With that, click-to-sort and `TableColumn.width(min:ideal:max:)` work.
//
// The remaining blocker is the filter row. This design interleaves a
// per-column filter `TextField` row under the header. Native `Table` owns
// its header and doesn't expose custom header content on macOS 14, so a
// migration must lift the filter row above the table as a separate bar.
// Once users can resize `Table` columns, keeping that external bar aligned
// requires a `PreferenceKey` width-sync system — ~250–400 LOC of layout
// plumbing to replace features we already have working. The current
// `LazyVStack` gives us integrated filter row, single/double-click selection,
// context menu, and debounced filters for far less code.
//
// When the cost of migration is worth it (user-requested multi-select,
// drag-resize, native VoiceOver table nav), the model layer
// (`SearchResultsModel`, `SearchResultColumns`, `ColumnKind`-aware sort,
// `col.idealWidth`) is shaped correctly for a drop-in. Until then, this
// hand-rolled approach is the pragmatic choice, not a limitation.
struct SearchResultsView: View {
    var resultsModel: SearchResultsModel
    var tapClient: TAPClient
    var researchModel: ResearchModel?
    /// Invoked when the user clicks a quick-search cell. Called on MainActor
    /// with `(columnID, rawValue)`; wire through to
    /// ``SearchFormModel/quickSearch(columnID:rawValue:)``.
    var onQuickSearch: ((String, String) -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @State private var selectedResult: SearchResult?
    @State private var selectedRowID: String?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @State private var showExportError = false
    @State private var showColumnsPicker = false
    @FocusState private var focusedFilter: String?

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $selectedResult) { result in
            ResultDetailSheet(
                result: result,
                columns: resultsModel.columns,
                tapClient: tapClient,
                researchModel: researchModel
            )
        }
        .alert("Export failed", isPresented: $showExportError, presenting: exportErrorMessage) { _ in
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onChange(of: exportErrorMessage) { _, new in
            showExportError = (new != nil)
        }
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        HStack {
            if resultsModel.totalRows > 0 {
                // Interpolations coerce Int → String so catalog keys are
                // `%@ of %@ results` / `%@ rows (limit reached)` / `%@ results`
                // (the object-typed forms that already have French). Raw Int
                // interpolation would produce `%lld …` keys that aren't in
                // the catalog and fall back to English.
                if resultsModel.filteredCount != resultsModel.totalRows {
                    Text("\(String(resultsModel.filteredCount)) of \(String(resultsModel.totalRows)) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if resultsModel.maxRecordReached {
                    Label(
                        "\(String(resultsModel.totalRows)) rows (limit reached)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text(
                        "\(String(resultsModel.totalRows)) rows loaded — server record limit reached, more rows may exist"
                    ))
                } else {
                    Text("\(String(resultsModel.totalRows)) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Pagination — show page controls only when needed; always expose
            // the page-size picker so the user can change it even on page 1 of 1.
            if resultsModel.totalPages > 1 {
                HStack(spacing: 4) {
                    Button {
                        resultsModel.currentPage = max(0, resultsModel.currentPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(resultsModel.currentPage == 0)
                    .keyboardShortcut("[", modifiers: [.command])
                    .help(Text("Previous page"))

                    Text("\(resultsModel.currentPage + 1)/\(resultsModel.totalPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40)

                    Button {
                        resultsModel.currentPage = min(resultsModel.totalPages - 1, resultsModel.currentPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(resultsModel.currentPage >= resultsModel.totalPages - 1)
                    .keyboardShortcut("]", modifiers: [.command])
                    .help(Text("Next page"))
                }
            }

            if !resultsModel.results.isEmpty {
                Picker("", selection: Bindable(resultsModel).rowsPerPage) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("All (≤\(SearchResultsModel.maxRowsForAll))").tag(0)
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .help(Text("Rows per page"))
            }

            exportMenu
            columnsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var exportMenu: some View {
        Menu {
            Section("Current View") {
                Button("CSV (filtered)") { Task { await exportClientSide(format: .csv) } }
                Button("TSV (filtered)") { Task { await exportClientSide(format: .tsv) } }
            }
            Section("Full Query (server)") {
                Button("CSV") { Task { await exportServerSide(format: "csv", ext: "csv") } }
                Button("TSV") { Task { await exportServerSide(format: "tsv", ext: "tsv") } }
                Button("VOTable") { Task { await exportServerSide(format: "votable", ext: "xml") } }
            }
        } label: {
            HStack(spacing: 4) {
                if isExporting { ProgressView().scaleEffect(0.6) }
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
        }
        .disabled(resultsModel.results.isEmpty || isExporting)
        .keyboardShortcut("e", modifiers: [.command, .shift])
    }

    private var columnsMenu: some View {
        Button {
            showColumnsPicker.toggle()
        } label: {
            Label("Columns", systemImage: "tablecells")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(Text("Choose visible columns"))
        .popover(isPresented: $showColumnsPicker, arrowEdge: .top) {
            ColumnsPickerPopover(model: resultsModel)
        }
    }

    // MARK: - Results Table

    private var resultsTable: some View {
        let visibleCols = resultsModel.columns.visible

        return GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(resultsModel.displayedRows) { result in
                                resultRow(result, columns: visibleCols)
                            }
                        } header: {
                            VStack(spacing: 0) {
                                sortableHeaderRow(columns: visibleCols)
                                filterRow(columns: visibleCols)
                                Divider()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: geo.size.height)
            }
        }
        .background(
            // Hidden shortcut — focuses first visible filter field.
            Button("") { focusedFilter = visibleCols.first?.id }
                .keyboardShortcut("f", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func sortableHeaderRow(columns: [SearchResultColumn]) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 30)
                .accessibilityLabel(Text("Preview"))

            ForEach(columns) { col in
                HStack(spacing: 4) {
                    Button { resultsModel.toggleSort(col.id) } label: {
                        HStack(spacing: 2) {
                            Text(col.label)
                                .font(.caption.bold())
                            if resultsModel.sortColumnID == col.id {
                                Image(systemName: resultsModel.sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(col.label))

                    unitMenu(for: col)

                    Spacer(minLength: 0)
                }
                .frame(width: col.idealWidth, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .background(.bar)
    }

    /// Unit-switch menu for columns with multiple display units. Renders as
    /// a small slider glyph; opens a menu of choices on tap. Absent for
    /// single-unit columns.
    @ViewBuilder
    private func unitMenu(for col: SearchResultColumn) -> some View {
        if let choices = CellFormatterRegistry.availableUnits(for: col.id), choices.count > 1 {
            let current = resultsModel.selectedUnit(for: col.id)
            Menu {
                ForEach(choices, id: \.unitID) { choice in
                    Button {
                        resultsModel.setUnit(columnID: col.id, unitID: choice.unitID)
                    } label: {
                        if choice.unitID == current {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Display unit"))
        }
    }

    private func filterRow(columns: [SearchResultColumn]) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 30)

            ForEach(columns) { col in
                DebouncedFilterField(
                    columnID: col.id,
                    currentValue: resultsModel.columnFilters[col.id] ?? "",
                    onCommit: { text in resultsModel.setFilter(col.id, text: text) }
                )
                .focused($focusedFilter, equals: col.id)
                .frame(width: col.idealWidth)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
        }
        .background(.bar.opacity(0.5))
    }

    private func resultRow(_ result: SearchResult, columns: [SearchResultColumn]) -> some View {
        let isSelected = selectedRowID == result.id

        return HStack(spacing: 0) {
            PreviewThumbnailCell(
                publisherID: resultsModel.columns.value(in: result, forID: "publisherid"),
                tapClient: tapClient
            ) {
                selectedRowID = result.id
                selectedResult = result
            }
            .frame(width: 30)

            HStack(spacing: 0) {
                ForEach(columns) { col in
                    cell(for: col, in: result)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selectedRowID = result.id
                selectedResult = result
            }
            .onTapGesture(count: 1) {
                selectedRowID = result.id
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contextMenu {
            Button("Open Detail") {
                selectedRowID = result.id
                selectedResult = result
            }
            let pid = resultsModel.columns.value(in: result, forID: "publisherid")
            if !pid.isEmpty, let url = TAPClient.detailURL(publisherID: pid) {
                Button("Open on CADC…") { openURL(url) }
            }
            if !pid.isEmpty, let url = TAPClient.downloadURL(publisherID: pid) {
                Button("Download File…") { openURL(url) }
            }
            Divider()
            Button("Copy Row") { copyRow(result, columns: columns) }
        }
    }

    /// Render one cell. Quick-searchable columns become underlined buttons
    /// that re-narrow the current search on click; everything else is plain
    /// non-interactive text so the row-level tap gestures reach it.
    @ViewBuilder
    private func cell(for col: SearchResultColumn, in result: SearchResult) -> some View {
        let raw = resultsModel.columns.value(in: result, forID: col.id)
        let formatted = CellFormatterRegistry.format(
            id: col.id,
            raw: raw,
            unitID: resultsModel.selectedUnit(for: col.id)
        )

        if let onQuickSearch,
           SearchFormModel.quickSearchableColumnIDs.contains(col.id),
           !raw.isEmpty {
            Button {
                onQuickSearch(col.id, raw)
            } label: {
                Text(formatted)
                    .font(.caption)
                    .lineLimit(1)
                    .underline(pattern: .solid)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .frame(width: col.idealWidth, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .help(Text("Narrow search to \(col.label) = \(raw)"))
        } else {
            Text(formatted)
                .font(.caption)
                .lineLimit(1)
                .frame(width: col.idealWidth, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
    }

    private func copyRow(_ result: SearchResult, columns: [SearchResultColumn]) {
        let line = columns
            .map { col in
                CellFormatterRegistry.format(
                    id: col.id,
                    raw: resultsModel.columns.value(in: result, forID: col.id),
                    unitID: resultsModel.selectedUnit(for: col.id)
                )
            }
            .joined(separator: "\t")
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(line, forType: .string)
        #endif
    }

    // MARK: - Export

    private func exportServerSide(format: String, ext: String) async {
        guard let url = resultsModel.exportURL(format: format) else {
            exportErrorMessage = String(localized: "No export URL available for this query.")
            return
        }
        isExporting = true
        defer { isExporting = false }

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else {
                exportErrorMessage = String(localized: "Invalid server response.")
                return
            }
            guard http.statusCode == 200 else {
                exportErrorMessage = String(localized: "Export failed (HTTP \(http.statusCode)).")
                try? FileManager.default.removeItem(at: tempURL)
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
            exportErrorMessage = error.localizedDescription
        }
    }

    private func exportClientSide(format: ClientExporter.Format) async {
        let rows = resultsModel.fullFilteredSortedResults
        guard !rows.isEmpty else {
            exportErrorMessage = String(localized: "No rows to export.")
            return
        }
        isExporting = true
        defer { isExporting = false }

        let filename = "results.\(format.pathExtension)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try ClientExporter.write(
                rows: rows,
                columns: resultsModel.columns,
                format: format,
                to: tempURL
            )
            #if os(macOS)
            await presentExportSavePanel(filename: filename, tempURL: tempURL)
            #endif
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    @MainActor
    private func presentExportSavePanel(filename: String, tempURL: URL) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Results")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.directoryURL = docs

        let response = panel.runModal()
        if response == .OK, let saveURL = panel.url {
            try? FileHelper.moveReplacing(from: tempURL, to: saveURL)
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
    #endif
}

// DebouncedFilterField and ColumnsPickerPopover live in
// Views/Components/ for reuse and to keep this file focused on the
// results-table composition.
