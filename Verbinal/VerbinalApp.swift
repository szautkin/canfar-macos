// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

// Entry point lives in `VerbinalMain` so we can branch to the headless MCP
// stdio bridge before SwiftUI initializes. This is a plain `App`, driven by
// `VerbinalApp.main()` for the normal GUI launch path.
struct VerbinalApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .uiPointerOverlay()
                .uiWindowPlace(.main)
                .environment(appState)
                .environment(appState.uiPointer)
                .environment(\.locale, appState.locale)
                .frame(minWidth: 900, minHeight: 600)
                .task { NotificationService.requestPermissionIfNeeded() }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // File → Export All…
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export All…") {
                    appState.activeSheet = .export
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // App → About Verbinal (replaces the auto-generated "About" so
            // we can route to the existing AboutSheet rather than AppKit's
            // stock About panel).
            CommandGroup(replacing: .appInfo) {
                Button("About Verbinal") {
                    appState.activeSheet = .about
                }
            }

            // Go menu — mode navigation with ⌘-number shortcuts.
            // Portal + Storage use navigateOrPromptLogin semantics: when
            // signed out, selecting them opens the login sheet with
            // `pendingModeAfterLogin` set so a successful sign-in lands
            // the user on the intended screen.
            CommandMenu("Go") {
                Button("Landing") {
                    appState.navigateBack()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Search") {
                    appState.navigateTo(.search)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Research") {
                    appState.navigateTo(.research)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("FITS Viewer") {
                    appState.navigateTo(.fitsViewer)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Cube Viewer") {
                    appState.navigateTo(.cubeViewer)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Workflows") {
                    appState.navigateTo(.workflows)
                }

                Divider()

                Button("Portal") {
                    appState.navigateOrPromptLogin(.portal)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("Storage") {
                    appState.navigateOrPromptLogin(.storage)
                }
                .keyboardShortcut("6", modifiers: .command)

                Divider()

                // AI features. The AI Guide route exists independent of the
                // landing-tile toggle. Image Discovery has no AppMode — it's a
                // dashboard sheet — so we drive its existing binding directly.
                Button("AI Guide") {
                    appState.navigateTo(.aiGuide)
                }
                .keyboardShortcut("7", modifiers: .command)

                Button("Image Discovery…") {
                    appState.showImageDiscoverySheet = true
                }
                .keyboardShortcut("8", modifiers: .command)
            }

            // View menu additions — FITS-viewer zoom, targeting the
            // app-owned tab host so the shortcuts work without a focus
            // dance. ⌘0 belongs to Go ▸ Landing, so Actual Size / Fit
            // take ⌥⌘ variants. Disabled outside the FITS viewer.
            CommandGroup(after: .toolbar) {
                let activeTab = appState.currentMode == .fitsViewer
                    ? appState.fitsTabHost.activeTab : nil

                Divider()

                Button("Zoom In") {
                    if let tab = activeTab { tab.setZoom(tab.viewport.zoom * 1.25) }
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(activeTab == nil)

                Button("Zoom Out") {
                    if let tab = activeTab { tab.setZoom(tab.viewport.zoom / 1.25) }
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(activeTab == nil)

                Button("Actual Size") {
                    if let tab = activeTab { tab.setZoom(1.0) }
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(activeTab == nil)

                Button("Zoom to Fit") {
                    if let tab = activeTab, tab.lastCanvasSize.width > 0 {
                        tab.fitToWindow(canvasSize: tab.lastCanvasSize)
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(activeTab == nil)
            }

            // Help → in-app discovery first, then links to project + issue
            // tracker. macOS users reflexively check Help, so the flagship AI
            // setup and the feature index live at the top.
            CommandGroup(replacing: .help) {
                Button("What Verbinal Can Do…") {
                    appState.activeSheet = .features
                }
                Button("Connect an AI Agent…") {
                    appState.activeSheet = .mcpSetupWizard
                }
                Divider()
                Button("Verbinal Help") { NSWorkspace.shared.open(AppLinks.help) }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Report an Issue") { NSWorkspace.shared.open(AppLinks.newIssue) }
            }
        }

        Settings {
            SettingsView()
                .uiPointerOverlay()
                .uiWindowPlace(.settings)
                .environment(appState)
                .environment(appState.uiPointer)
                .environment(\.locale, appState.locale)
        }
        #else
        WindowGroup {
            ContentView()
                .environment(appState)
                .task { NotificationService.requestPermissionIfNeeded() }
        }
        #endif
    }
}
