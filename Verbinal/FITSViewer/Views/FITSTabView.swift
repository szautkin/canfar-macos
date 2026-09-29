// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
#if os(macOS)
import AppKit
#endif
import VerbinalKit

/// Multi-tab container for FITS viewer instances.
struct FITSTabView: View {
    var tabHost: FITSTabHostModel
    @Environment(AppState.self) private var appState
    @State private var showHeader = false
    @State private var showBookmarks = false
    @State private var showMarks = false
    @Environment(\.fitsToast) private var toast

    /// App-owned (see `AppState.fitsBookmarks`): the agent bookmark tools
    /// write to the same live store the panel renders, so a tool-saved
    /// bookmark appears immediately instead of on next launch.
    private var bookmarkStore: BookmarkStore { appState.fitsBookmarks }

    #if os(macOS)
    /// Retains the NSEvent local monitor while blink is active.
    @State private var blinkKeyMonitor: Any?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            if tabHost.tabCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabHost.tabs.enumerated()), id: \.offset) { index, tab in
                            tabButton(index: index, tab: tab)
                        }

                        // New tab button (⌘T — standard macOS new-tab shortcut)
                        Button {
                            _ = tabHost.addTab()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .accessibilityLabel(Text("New tab"))
                        .buttonStyle(.plain)
                        .keyboardShortcut("t", modifiers: [.command])
                        .help(Text("New tab (⌘T)"))
                        .accessibilityLabel(Text("New tab"))
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 28)
                .background(.bar)
                .background(
                    // Hidden close-active-tab shortcut (⌘W).
                    // Disabled when there are no tabs to avoid swallowing
                    // ⌘W from other parts of the window.
                    Button("") {
                        if tabHost.tabCount > 0 { tabHost.closeActiveTab() }
                    }
                    .keyboardShortcut("w", modifiers: [.command])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .disabled(tabHost.tabCount == 0)
                    .accessibilityHidden(true)
                )

                // Linked controls — always visible, disabled when < 2 tabs
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { tabHost.linkedState.linkCrosshair },
                                         set: { tabHost.setLinkCrosshair($0) })) {
                        Label("Link Crosshair", systemImage: "scope")
                            .font(.caption2)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .disabled(!tabHost.hasMultipleTabs)
                    .help("Sync crosshair position across tabs via WCS coordinates")

                    Toggle(isOn: Bindable(tabHost.linkedState).linkZoom) {
                        Label("Sync Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .disabled(!tabHost.hasMultipleTabs)
                    .help("Match angular extent across tabs")

                    Divider().frame(height: 12)

                    if tabHost.isBlinking {
                        Button { tabHost.stopBlink() } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .keyboardShortcut(.escape, modifiers: [])

                        Button { tabHost.toggleBlinkPause() } label: {
                            Label(tabHost.isBlinkPaused ? "Resume" : "Pause", systemImage: tabHost.isBlinkPaused ? "play.fill" : "pause.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("A") { tabHost.showBlinkA() }
                            .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                            .help("Show image A")
                        Button("B") { tabHost.showBlinkB() }
                            .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                            .help("Show image B")

                        Slider(value: Bindable(tabHost).blinkInterval, in: 0.5...5.0, step: 0.5) {
                            Text(String(format: "%.1fs", tabHost.blinkInterval))
                                .font(.caption2)
                                .frame(width: 30)
                        }
                        .frame(width: 120)
                        .help("Blink interval (0.5–5.0 seconds)")

                        if tabHost.blinkTransform == nil {
                            Label("No WCS — unaligned", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                    } else {
                        // Direct button for exactly 2 tabs; Menu for 3+ tabs
                        if tabHost.tabs.count == 2 {
                            let otherIndex = tabHost.activeTabIndex == 0 ? 1 : 0
                            Button {
                                tabHost.startBlink(tabA: tabHost.activeTabIndex, tabB: otherIndex)
                            } label: {
                                Label("Blink", systemImage: "rectangle.2.swap")
                                    .font(.caption2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .keyboardShortcut("b", modifiers: [.command, .shift])
                            .help("Blink current tab against another tab (Space=pause, ←=A, →=B, Esc=stop)")
                        } else {
                            Menu {
                                ForEach(Array(tabHost.tabs.enumerated()), id: \.offset) { index, tab in
                                    if index != tabHost.activeTabIndex {
                                        Button(tab.fileURL?.lastPathComponent ?? "Tab \(index + 1)") {
                                            tabHost.startBlink(tabA: tabHost.activeTabIndex, tabB: index)
                                        }
                                    }
                                }
                            } label: {
                                Label("Blink", systemImage: "rectangle.2.swap")
                                    .font(.caption2)
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.mini)
                            .disabled(tabHost.tabs.count < 2)
                            .help("Blink current tab against another tab (Space=pause, ←=A, →=B, Esc=stop)")
                        }
                    }

                    // Cross-tab sync is only as accurate as the least-precise
                    // linked WCS — warn when any tab is missing/invalid/approximate.
                    let imprecise = tabHost.tabsWithImpreciseWCS
                    if !imprecise.isEmpty {
                        Label(String(localized: "No precise WCS in \(imprecise.map(\.displayName).joined(separator: ", ")) — sync may be imprecise"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("A linked tab has missing, invalid, or approximate WCS. Crosshair and zoom sync across tabs may not land on the exact sky position.")
                    }
                    // A linked crosshair has nowhere to land in a field elsewhere on the sky.
                    let apart = tabHost.fieldsApartFromActive
                    if !apart.isEmpty {
                        Label(String(localized: "No shared sky with \(apart.map(\.displayName).joined(separator: ", "))"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("These tabs show another part of the sky, so the linked crosshair has no place in them.")
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

                Divider()
            }

            // Active tab content
            if let activeModel = tabHost.activeTab {
                HSplitView {
                    // Sidebar: HDU list + controls + header
                    VStack(alignment: .leading, spacing: 0) {
                        fitsToolbar(activeModel)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                hduList(activeModel)
                                FITSRenderControlsView(model: activeModel, marks: appState.marks)
                                if showHeader {
                                    Divider()
                                    FITSImageInfoPanel(model: activeModel)
                                    Divider()
                                    FITSHeaderPanel(model: activeModel)
                                        .frame(minHeight: 150)
                                }
                                if showBookmarks {
                                    Divider()
                                    FITSBookmarkPanel(model: activeModel, store: bookmarkStore)
                                        .frame(minHeight: 100)
                                }
                                if showMarks {
                                    Divider()
                                    MarksPanel(editor: appState.fitsMarkEditor, target: activeModel.markTarget,
                                               host: activeModel.markTarget.map {
                                                   FITSMarkCommands(tab: activeModel, editor: appState.fitsMarkEditor,
                                                                    target: $0, say: { toast?.show($0) })
                                               })
                                }
                            }
                        }
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    // Viewer
                    VStack(spacing: 0) {
                        if activeModel.isLoading {
                            Spacer()
                            VStack(spacing: 8) {
                                ProgressView()
                                Text(activeModel.loadStage).font(.caption.monospaced())
                                Text(activeModel.fileURL?.lastPathComponent ?? "").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .accessibilityElement(children: .combine)
                            Spacer()
                        } else if let error = activeModel.loadError {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title).foregroundStyle(.orange)
                                Text(error).font(.caption)
                                Button("Retry") {
                                    if let url = activeModel.fileURL {
                                        Task { await activeModel.open(url: url) }
                                    }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                            Spacer()
                        } else if activeModel.renderedImage != nil {
                            FITSImageView(model: activeModel, tabHost: tabHost, marks: appState.fitsMarkEditor)
                            Divider()
                            FITSCoordinateBar(model: activeModel)
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transaction { $0.animation = nil }
            } else {
                emptyState
            }
        }
        #if os(macOS)
        .onChange(of: tabHost.isBlinking) { _, blinking in
            if blinking {
                installBlinkKeyMonitor()
            } else {
                removeBlinkKeyMonitor()
            }
        }
        .onDisappear { removeBlinkKeyMonitor() }
        #endif
    }

    // MARK: - Blink Keyboard Controls (macOS)

    #if os(macOS)
    /// Install a local NSEvent key monitor for blink keyboard shortcuts.
    ///
    /// Uses a local (not global) monitor so it only fires when the app is active.
    /// The monitor is removed when blink stops or the view disappears.
    ///
    /// Shortcuts (matching Windows FitsTabHost.OnKeyDown):
    ///   - Space     → toggle pause/resume
    ///   - Left arrow → show image A (opacity=0, freeze)
    ///   - Right arrow → show image B (opacity=1, freeze)
    ///   (Esc is handled by the Stop button's .keyboardShortcut modifier)
    private func installBlinkKeyMonitor() {
        guard blinkKeyMonitor == nil else { return }
        blinkKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard tabHost.isBlinking else {
                removeBlinkKeyMonitor()
                return event
            }
            switch event.keyCode {
            case 49: // Space
                tabHost.toggleBlinkPause()
                return nil
            case 123: // Left arrow
                tabHost.showBlinkA()
                return nil
            case 124: // Right arrow
                tabHost.showBlinkB()
                return nil
            default:
                return event
            }
        }
    }

    private func removeBlinkKeyMonitor() {
        if let monitor = blinkKeyMonitor {
            NSEvent.removeMonitor(monitor)
            blinkKeyMonitor = nil
        }
    }
    #endif

    // MARK: - Tab Button

    private func tabButton(index: Int, tab: FITSViewerModel) -> some View {
        let title = tab.displayName
        return HStack(spacing: 4) {
            Button {
                tabHost.activeTabIndex = index
            } label: {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(index == tabHost.activeTabIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text("Switch to this FITS tab"))

            if tabHost.hasMultipleTabs {
                Button {
                    tabHost.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Close tab"))
                .accessibilityHint(Text("Close \(title)"))
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Sidebar Components

    private func fitsToolbar(_ model: FITSViewerModel) -> some View {
        HStack {
            #if os(macOS)
            Button {
                Task { await model.openWithPicker() }
            } label: {
                Label("Open", systemImage: "doc.badge.plus").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            #endif

            Button { showHeader.toggle() } label: {
                Label("Header", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Toggle FITS header panel")

            Button { showBookmarks.toggle() } label: {
                Label("Bookmarks", systemImage: "bookmark")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Toggle coordinate bookmarks panel")

            Button { showMarks.toggle() } label: {
                Label("Marks", systemImage: "pencil.and.outline")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Toggle the marks panel: draw, list and export marks")

            Spacer()
        }
        .padding(8)
    }

    private func hduList(_ model: FITSViewerModel) -> some View {
        Group {
            if !model.imageHDUs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HDUs").font(.caption.bold()).padding(.horizontal, 8)
                    ForEach(model.imageHDUs) { hdu in
                        Button {
                            Task { await model.selectHDU(hdu.id) }
                        } label: {
                            HStack {
                                Image(systemName: model.selectedHDUIndex == hdu.id ? "circle.fill" : "circle")
                                    .font(.caption2)
                                Text(hdu.label).font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("No FITS file open", systemImage: "star.circle")
            } description: {
                Text("Open a FITS file or drag one here.")
            } actions: {
                #if os(macOS)
                Button("Open FITS File…") { Task { await (tabHost.activeTab ?? tabHost.addTab()).openWithPicker() } }
                    .buttonStyle(.borderedProminent)
                #endif
            }
            .fixedSize(horizontal: false, vertical: true)
            RecentFilesList(recents: RecentFiles.fits, icon: "star.circle") { recent in
                Task {
                    guard let url = RecentFiles.fits.resolve(recent) else {
                        toast?.show(String(localized: "“\(recent.name)” is no longer available."))
                        return
                    }
                    await tabHost.openFile(url: url)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
