// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// AI Guide — a dashboard-style screen that surfaces every built-in MCP tool,
/// grouped into category widgets, plus a "My Guides" widget for user-authored
/// instruction tools.
///
/// Reuses the dashboard's `GroupBox` + `Label` header rhythm (see
/// `CanfarImagesView` / `RecentLaunchesView`) so the screen reads as a unified
/// stack of panels. Editing a built-in tool's description expands an inline
/// accordion editor on its ``AIGuideToolRow`` (no modal) that writes an override
/// into the app DB; the override is what the MCP server advertises in
/// `tools/list`, re-tuning the agent live.
struct AIGuideView: View {
    @Environment(AppState.self) private var appState

    /// Existing guide-tool editor target.
    @State private var editingGuide: AIGuideToolEntry?
    /// New guide-tool sheet.
    @State private var creatingGuide = false
    /// Live filter applied across every built-in tool (name + description).
    @State private var searchText = ""

    /// Persisted launchpad/full-grid choice. Tiles is the default mode.
    @AppStorage("aiGuide.viewMode") private var viewMode: AIGuideViewMode = .tiles
    /// `nil` = launchpad; non-nil = a category's focus panel is expanded.
    @State private var focusedCategoryID: String?
    /// The focus panel's inline-edit target. Lives here (not on the panel) so it
    /// survives the open/close animation; reset to `nil` in `close()`.
    @State private var focusEditingToolName: String?
    /// Each tile's frame in `"aiGuideRoot"` space — drives the panel scale anchor.
    @State private var tileFrames: [String: CGRect] = [:]
    /// Viewport size, for the scale anchor `UnitPoint` and the panel height cap.
    @State private var rootSize: CGSize = .zero
    /// Moves keyboard/VoiceOver focus into the panel once it mounts.
    @FocusState private var panelFocused: Bool
    /// Returns VoiceOver focus to the source tile on close.
    @AccessibilityFocusState private var a11yTile: String?
    /// Moves VoiceOver focus into the panel on open.
    @AccessibilityFocusState private var a11yPanel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Launchpad (tiles) vs the full categorized grid ("See Everything").
    enum AIGuideViewMode: String, CaseIterable { case tiles, everything }

    private var service: AIGuideService { appState.aiGuideService }

    /// Persist a built-in tool's description override. Returns `nil` on success,
    /// else a user-facing error string the row shows inline. This is the single
    /// throwing→String adapter every inline editor (search cards, the full grid,
    /// the focus panel) routes through, so the rows stay `AIGuideService`-free
    /// and behave identically. `setOverride` trims and clears the override on an
    /// empty value, and throws over the char cap.
    private func saveOverride(_ name: String, _ description: String) -> String? {
        do {
            try service.setOverride(toolName: name, description: description)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Adaptive grid: 1 column below ~760pt, 2 up to ~1130pt, 3 above. The
    /// `maximum` stops a lone card ballooning to full width; `.top` alignment
    /// top-aligns short cards so a ragged bottom reads as deliberate spacing.
    private let cardColumns = [
        GridItem(.adaptive(minimum: 360, maximum: 520), spacing: 16, alignment: .top)
    ]

    /// Tiles carry no rows, so they can be denser than the 360pt category cards:
    /// ~520pt → 1 col, ~700pt → 2 cols, ~1100pt → 3–4 cols.
    private let tileColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16, alignment: .top)
    ]

    /// Live tool rows (built-in default ⊕ user override), grouped + ordered by
    /// category. Empty categories are dropped so the screen has no dead panels.
    private var grouped: [(category: AIGuideCatalog.Category, rows: [AIGuideTool])] {
        let rows = service.rows(forTools: appState.aiGuideToolInputs())
        let byCategory = Dictionary(grouping: rows, by: { $0.category })
        return AIGuideCatalog.allCategories.compactMap { category in
            guard let catRows = byCategory[category.id], !catRows.isEmpty else { return nil }
            return (category, catRows.sorted { $0.name < $1.name })
        }
    }

    // MARK: - Derived (presentation-only projections over `grouped`)

    /// Every live tool row, flattened from `grouped` (no second data source).
    private var allRows: [AIGuideTool] { grouped.flatMap(\.rows) }

    /// How many built-in tools currently carry a user override.
    private var overriddenCount: Int { allRows.lazy.filter(\.isOverridden).count }

    /// Tools matching the live query (name or effective description), sorted by
    /// name. Empty while the query is blank — the categorized grid renders then.
    private var filteredRows: [AIGuideTool] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allRows
            .filter { $0.name.lowercased().contains(q)
                   || $0.effectiveDescription.lowercased().contains(q) }
            .sorted { $0.name < $1.name }
    }

    /// Human title for a category id, for the flat-search card subtitle.
    private func categoryTitle(_ id: String) -> String {
        AIGuideCatalog.allCategories.first { $0.id == id }?.title ?? AIGuideCatalog.other.title
    }

    /// The grouped `(category, rows)` pair for a category id, or `nil`.
    private func group(forID id: String) -> (category: AIGuideCatalog.Category, rows: [AIGuideTool])? {
        grouped.first { $0.category.id == id }
    }

    var body: some View {
        ZStack {
            scrollContent
                // Pin the named space to the root so tile frames + the scale
                // anchor stay correct regardless of how far the grid scrolled.
                .coordinateSpace(name: "aiGuideRoot")
                .onPreferenceChange(TileFrameKey.self) { tileFrames = $0 }
                // While a panel is up, dim + (unless Reduce Motion) blur the
                // grid in place — never relaid out — and trap focus in the panel.
                .blur(radius: (focusedCategoryID == nil || reduceMotion) ? 0 : 8)
                .disabled(focusedCategoryID != nil)
                .accessibilityHidden(focusedCategoryID != nil)

            if let id = focusedCategoryID, let group = group(forID: id) {
                focusOverlay(group)
                    .zIndex(1)
            }
        }
        // Viewport size for the scale anchor and panel height cap.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RootSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(RootSizeKey.self) { rootSize = $0 }
        // Typing while a panel is open closes it first, so search never stacks
        // over the overlay.
        .onChange(of: searchText) { _, new in
            if !new.isEmpty, focusedCategoryID != nil { close() }
        }
        .sheet(item: $editingGuide) { guide in
            AIGuideEntryEditSheet(mode: .edit(guide))
        }
        .sheet(isPresented: $creatingGuide) {
            AIGuideEntryEditSheet(mode: .create)
        }
    }

    // MARK: - Scroll content (header + My Guides + mode-routed body)

    /// The launchpad's scrollable column. Routing precedence: a non-empty search
    /// supersedes the mode and shows the flat results in either mode; otherwise
    /// the persisted `viewMode` decides tiles vs. the full grid.
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AIGuideSummaryHeader(
                    totalTools: allRows.count,
                    overriddenCount: overriddenCount,
                    categoryCount: grouped.count,
                    searchText: $searchText,
                    matchCount: searchText.isEmpty ? nil : filteredRows.count
                )
                myGuidesWidget

                if !searchText.isEmpty {
                    searchResults.transition(.appFade)
                } else if grouped.isEmpty {
                    noToolsUnavailable.transition(.appFade)
                } else {
                    modeToggle
                    switch viewMode {
                    case .tiles:      tileLaunchpad.transition(.appFade)
                    case .everything: everythingGrid.transition(.appFade)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Cross-fade two STATE BOUNDARIES — entering/leaving search
            // (`searchText.isEmpty`) and toggling Tiles↔See-Everything
            // (`viewMode`). Keyed on the boundary, NOT on `searchText` or
            // `filteredRows`, so per-keystroke re-filtering stays instant.
            .appAnimation(AppMotion.stateSwap, value: routeKey)
        }
    }

    /// Lightweight discriminator for the `scrollContent` cross-fade. Captures
    /// only the search-mode boundary and the view mode — typing into a
    /// non-empty query leaves this unchanged, so the flat results re-filter
    /// without animating.
    private struct RouteKey: Equatable {
        let searching: Bool
        let mode: AIGuideViewMode
    }

    private var routeKey: RouteKey {
        RouteKey(searching: !searchText.isEmpty, mode: viewMode)
    }

    /// Flat search results (and the empty state) — shown in both modes. Verbatim
    /// from the prior implementation.
    @ViewBuilder
    private var searchResults: some View {
        if filteredRows.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ForEach(filteredRows) { row in
                    AIGuideToolCard(
                        row: row,
                        categoryTitle: categoryTitle(row.category),
                        onSave: saveOverride,
                        onReset: { service.clearOverride(toolName: row.name) }
                    )
                }
            }
        }
    }

    /// Shown when no agent tools are registered yet (e.g. before they're
    /// composed). Without this the main area would render blank.
    private var noToolsUnavailable: some View {
        ContentUnavailableView(
            "No Tools Yet",
            systemImage: "wrench.and.screwdriver",
            description: Text("The agent's tools appear here once they're registered.")
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mode toggle

    /// Right-aligned segmented toggle between the tile launchpad and the full
    /// "See Everything" grid. Only rendered inside the not-searching branch, so
    /// it appears solely when there's something to toggle between.
    private var modeToggle: some View {
        HStack(spacing: 8) {
            Spacer()
            Text("View:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("View", selection: $viewMode) {
                Text("Tiles").tag(AIGuideViewMode.tiles)
                Text("See Everything").tag(AIGuideViewMode.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    // MARK: - Tile launchpad (default mode)

    private var tileLaunchpad: some View {
        LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 16) {
            ForEach(grouped, id: \.category.id) { group in
                AIGuideCategoryTile(
                    category: group.category,
                    toolCount: group.rows.count,
                    hasOverrides: group.rows.contains(where: \.isOverridden),
                    onOpen: { open(group.category.id) }
                )
                .accessibilityFocused($a11yTile, equals: group.category.id)
                // Capture the tile's frame in root space (read-only) so the
                // panel can scale out of this tile's location.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TileFrameKey.self,
                            value: [group.category.id: geo.frame(in: .named("aiGuideRoot"))]
                        )
                    }
                )
                // Hide the source tile while its panel is up (no duplicate).
                .opacity(focusedCategoryID == group.category.id ? 0 : 1)
            }
        }
    }

    // MARK: - Full grid ("See Everything" mode, verbatim from before)

    private var everythingGrid: some View {
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
            ForEach(grouped, id: \.category.id) { group in
                AIGuideCategoryCard(
                    category: group.category,
                    rows: group.rows,
                    onSave: saveOverride,
                    onReset: { service.clearOverride(toolName: $0.name) }
                )
            }
        }
    }

    // MARK: - Focus overlay (dim backdrop + centered panel)

    @ViewBuilder
    private func focusOverlay(_ g: (category: AIGuideCatalog.Category, rows: [AIGuideTool])) -> some View {
        // Backdrop: dim + tap-to-close. Blur is applied to the GRID (see body),
        // so the panel stays crisp. Hidden from VoiceOver — it never lands here.
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityHidden(true)
            .transition(.opacity)

        AIGuideFocusPanel(
            category: g.category,
            rows: g.rows,
            editingToolName: $focusEditingToolName,
            onSave: saveOverride,
            onReset: { service.clearOverride(toolName: $0.name) },
            onClose: { close() }
        )
        .focused($panelFocused)
        .frame(maxWidth: 560)
        .frame(maxHeight: panelMaxHeight)
        .padding(40)
        // Fill the viewport FIRST so the scale transition's `anchor` UnitPoint is
        // resolved in viewport space — that is what makes a corner tile's panel
        // grow *from the corner* and settle centered (frame-before-transition).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            // Single, edit-aware Esc owner for the panel: cancel an in-progress
            // inline edit first; close the panel only when nothing is editing —
            // so a mid-edit Esc can never lose the panel + draft.
            if focusEditingToolName != nil { focusEditingToolName = nil } else { close() }
        }
        .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.3, anchor: anchorPoint(for: g.category.id)).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("\(g.category.title) details")
        .accessibilityFocused($a11yPanel)
    }

    /// Cap the panel to the visible viewport so tall categories scroll inside.
    private var panelMaxHeight: CGFloat {
        rootSize.height > 0 ? min(rootSize.height - 96, rootSize.height * 0.82) : 560
    }

    /// The tapped tile's center as a `UnitPoint`, for the scale-from-tile anchor.
    /// Falls back to `.center` before the frame/size are known.
    private func anchorPoint(for id: String) -> UnitPoint {
        guard let f = tileFrames[id], rootSize.width > 0, rootSize.height > 0 else { return .center }
        return UnitPoint(x: min(max(f.midX / rootSize.width, 0), 1),
                         y: min(max(f.midY / rootSize.height, 0), 1))
    }

    // MARK: - open / close

    private func open(_ id: String) {
        if reduceMotion {
            focusedCategoryID = id                       // instant; .opacity cross-fades
        } else {
            withAnimation(AppMotion.hero) { focusedCategoryID = id }
        }
        // Move keyboard + VoiceOver focus into the panel once it mounts.
        DispatchQueue.main.async {
            panelFocused = true
            a11yPanel = true
        }
    }

    private func close() {
        let returning = focusedCategoryID
        panelFocused = false
        // A reopened panel should start collapsed, not mid-edit.
        focusEditingToolName = nil
        if reduceMotion {
            focusedCategoryID = nil
        } else {
            withAnimation(AppMotion.hero) { focusedCategoryID = nil }
        }
        if let returning { DispatchQueue.main.async { a11yTile = returning } }
    }

    // MARK: - My Guides widget

    private var myGuidesWidget: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("My Guides", systemImage: "book.closed")
                        .font(.headline)
                    Spacer()
                    Button {
                        creatingGuide = true
                    } label: {
                        Label("New Guide", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                Text("Custom read-only instruction tools you author. The agent sees each as a callable tool in `tools/list` and receives your text when it calls it — no code runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if service.guides.isEmpty {
                    emptyGuides
                } else {
                    ForEach(service.guides) { guide in
                        guideRow(guide)
                        if guide.id != service.guides.last?.id { Divider() }
                    }
                }
            }
            .padding(4)
        }
    }

    private var emptyGuides: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.tertiary)
            Text("No guides yet. Add one to teach the agent a workflow, a naming convention, or a project rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func guideRow(_ guide: AIGuideToolEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Text(guide.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = guide.body, !body.isEmpty {
                    Text("Returns \(body.count) characters of instructions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Edit") { editingGuide = guide }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
#endif
