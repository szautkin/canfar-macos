// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit
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
    /// What the search asked for, for a cutout of one of its results.
    var searchCutout = SearchCutout()
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

    /// Boundary discriminator for the empty↔results cross-fade.
    private var resultsState: DataState {
        resultsModel.results.isEmpty ? .empty : .content
    }

    /// Empty↔results boundary cross-fade. Extracted into its own property so the
    /// `body` expression stays inside the SwiftUI type-checker's complexity
    /// budget. Cross-fades only the empty↔results BOUNDARY — sorting/filtering
    /// the (up to 2000-row) table keeps the state at `.content`, so the reorder
    /// stays INSTANT, never a per-row move on a large list.
    private var resultsStateContent: some View {
        DataStateContainer(state: resultsState) {
            EmptyView()
        } empty: {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Run a search to see results here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } error: {
            EmptyView()
        } content: {
            resultsTable
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            resultsStateContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: selectedResult?.id, initial: true) { _, open in resultsModel.openDetailRowID = open }
        .sheet(item: $selectedResult) { result in
            ObservationDetailViewer(
                model: ObservationDetailModel(
                    result: result,
                    columns: resultsModel.columns
                ),
                tapClient: tapClient,
                researchModel: researchModel,
                searchCutout: searchCutout
            )
            .iosSheetChrome([.medium, .large])
        }
        .alert("Export failed", isPresented: $showExportError, presenting: exportErrorMessage) { _ in
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onChange(of: exportErrorMessage) { _, new in
            showExportError = (new != nil)
        }
        // `open_observation_detail` bridge — the sheet is local @State, so
        // the agent tool stamps a pending request on the model and the view
        // (the only owner of `selectedResult`) applies it here.
        .task(id: resultsModel.pendingDetailRequest) {
            guard let request = resultsModel.pendingDetailRequest else { return }
            resultsModel.pendingDetailRequest = nil
            guard let result = resultsModel.result(forID: request.rowID) else { return }
            selectedRowID = result.id
            selectedResult = result
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
                    .accessibilityLabel(Text("Previous page"))
                    .buttonStyle(.borderless)
                    .disabled(resultsModel.currentPage == 0)
                    .keyboardShortcut("[", modifiers: [.command])
                    .help(Text("Previous page"))
                    .accessibilityLabel("Previous page")

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
                    .accessibilityLabel(Text("Next page"))
                    .buttonStyle(.borderless)
                    .disabled(resultsModel.currentPage >= resultsModel.totalPages - 1)
                    .keyboardShortcut("]", modifiers: [.command])
                    .help(Text("Next page"))
                    .accessibilityLabel("Next page")
                }
                .pointable("results.pages", label: String(localized: "Previous and next page"), screen: "search.results")
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
                .pointable("results.rowsPerPage", label: String(localized: "Rows per page"), screen: "search.results")
            }

            exportMenu
            columnsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                if isExporting { ProgressView().controlSize(.small) }
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
        }
        .disabled(resultsModel.results.isEmpty || isExporting)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .pointable("results.export", label: String(localized: "Export"), screen: "search.results")
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
        .pointable("results.columns", label: String(localized: "Columns"), screen: "search.results")
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
                                    .pointable("results.header", label: String(localized: "Column headers — sort and units"),
                                               screen: "search.results")
                                filterRow(columns: visibleCols)
                                    .pointable("results.filters", label: String(localized: "Column filters"), screen: "search.results")
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
            .accessibilityLabel(Text("Display unit"))
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

        // Row interaction discipline:
        //   • Every cell is itself a `Button` (see `cell(for:in:)`). Plain
        //     cells select the row; quick-search cells run the narrow.
        //   • Double-click anywhere is a *simultaneous* gesture so the
        //     buttons get their single-tap reliably; the old design used
        //     `.onTapGesture(count: 1) + .onTapGesture(count: 2)` on the
        //     parent which forced SwiftUI to wait ~300 ms to resolve every
        //     tap and effectively swallowed the nested Button presses.
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
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedRowID = result.id
                selectedResult = result
            }
        )
        .contextMenu { rowMenu(result, columns: columns) }
    }

    /// The row's actions — on the row, and under each cell's own items.
    @ViewBuilder
    private func rowMenu(_ result: SearchResult, columns: [SearchResultColumn]) -> some View {
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
        if !pid.isEmpty, let researchModel {
            Button("Save to Research") {
                researchModel.saveToResearch(from: result, columns: resultsModel.columns)
            }
            .disabled(researchModel.isInResearch(publisherID: pid))
        }
        Divider()
        Button("Copy Details") { PlatformClipboard.copy(resultsModel.facts(for: result).detailsText) }
        Button("Copy Row") { PlatformClipboard.copy(resultsModel.tabSeparated([result], columns: columns)) }
        Button("Copy Page") {
            PlatformClipboard.copy(resultsModel.tabSeparated(resultsModel.displayedRows, columns: columns))
        }
    }

    /// Render one cell. A click selects the row (a double-click opens it);
    /// narrowing the search to a cell's value is on the cell's right-click
    /// menu, with copying it — a click that silently re-filtered the table
    /// was taken for "open this observation" (Windows 1.4.1).
    @ViewBuilder
    private func cell(for col: SearchResultColumn, in result: SearchResult) -> some View {
        let raw = resultsModel.columns.value(in: result, forID: col.id)
        let formatted = resultsModel.displayValue(of: result, columnID: col.id)
        let canNarrow = onQuickSearch != nil
            && SearchFormModel.quickSearchableColumnIDs.contains(col.id)
            && !raw.isEmpty

        Button {
            selectedRowID = result.id
        } label: {
            Text(formatted)
                .font(.caption)
                .lineLimit(1)
                .frame(width: col.idealWidth, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !formatted.isEmpty {
                Button("Copy “\(formatted)”") { PlatformClipboard.copy(formatted) }
            }
            if canNarrow {
                Button("Narrow Search to \(col.label) = \(raw)") { onQuickSearch?(col.id, raw) }
            }
            Divider()
            rowMenu(result, columns: resultsModel.columns.visible)
        }
    }

    // MARK: - Export

    private func exportServerSide(format: String, ext: String) async {
        guard let url = resultsModel.exportURL(format: format) else {
            exportErrorMessage = String(localized: "No export URL available for this query.")
            return
        }
        isExporting = true
        defer { isExporting = false }

        let session = ResultExportService.makeExportSession()
        defer { session.invalidateAndCancel() }
        do {
            let tempURL = try await ResultExportService.exportServerSide(
                url: url,
                ext: ext,
                session: session
            )
            #if os(macOS)
            await presentExportSavePanel(filename: "results.\(ext)", tempURL: tempURL)
            #else
            _ = tempURL
            #endif
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func exportClientSide(format: ClientExporter.Format) async {
        isExporting = true
        defer { isExporting = false }

        do {
            let tempURL = try ResultExportService.exportClientSide(
                rows: resultsModel.fullFilteredSortedResults,
                columns: resultsModel.columns,
                format: format
            )
            #if os(macOS)
            await presentExportSavePanel(filename: "results.\(format.pathExtension)", tempURL: tempURL)
            #else
            _ = tempURL
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
