// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Multi-tab container for FITS viewer instances.
struct FITSTabView: View {
    var tabHost: FITSTabHostModel
    @State private var showHeader = false
    @State private var showBookmarks = false
    private let bookmarkStore = BookmarkStore()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            if tabHost.tabCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabHost.tabs.enumerated()), id: \.offset) { index, tab in
                            tabButton(index: index, tab: tab)
                        }

                        // New tab button
                        Button {
                            _ = tabHost.addTab()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 28)
                .background(.bar)

                // Linked controls — always visible, disabled when < 2 tabs
                HStack(spacing: 8) {
                    Toggle(isOn: Bindable(tabHost.linkedState).linkCrosshair) {
                        Label("Link Crosshair", systemImage: "scope")
                            .font(.caption2)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .disabled(!tabHost.hasMultipleTabs)
                    .help("Sync crosshair position across tabs via WCS coordinates")
                    .onChange(of: tabHost.linkedState.linkCrosshair) { _, enabled in
                        if enabled {
                            for tab in tabHost.tabs {
                                tab.applyNorthUp()
                            }
                        }
                    }

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

                        Slider(value: Bindable(tabHost).blinkInterval, in: 0.2...3.0, step: 0.1) {
                            Text(String(format: "%.1fs", tabHost.blinkInterval))
                                .font(.caption2)
                                .frame(width: 30)
                        }
                        .frame(width: 120)
                        .help("Blink interval")

                    } else {
                        Button {
                            tabHost.startBlink(tabA: 0, tabB: 1)
                        } label: {
                            Label("Blink", systemImage: "eye.slash")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(tabHost.tabs.count < 2)
                        .help("Blink between first two tabs (Esc to stop)")
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
                                FITSRenderControlsView(model: activeModel)
                                if showHeader {
                                    Divider()
                                    FITSHeaderPanel(model: activeModel)
                                        .frame(minHeight: 150)
                                }
                                if showBookmarks {
                                    Divider()
                                    FITSBookmarkPanel(model: activeModel, store: bookmarkStore)
                                        .frame(minHeight: 100)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    // Viewer
                    VStack(spacing: 0) {
                        if activeModel.isLoading {
                            Spacer()
                            ProgressView("Loading FITS...")
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
                            FITSImageView(model: activeModel)
                            Divider()
                            FITSCoordinateBar(model: activeModel)
                        } else {
                            emptyState
                        }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Tab Button

    private func tabButton(index: Int, tab: FITSViewerModel) -> some View {
        HStack(spacing: 4) {
            Button {
                tabHost.activeTabIndex = index
            } label: {
                Text(tab.fileURL?.lastPathComponent ?? "Untitled")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(index == tabHost.activeTabIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            if tabHost.hasMultipleTabs {
                Button {
                    tabHost.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
        VStack(spacing: 12) {
            Image(systemName: "star.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No FITS file open").font(.title3).foregroundStyle(.secondary)
            Text("Open a FITS file or drag one here.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
