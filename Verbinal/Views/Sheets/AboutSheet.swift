// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct AboutSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showTerms = false
    @State private var copied = false
    /// Read once, when About opens — what is running now.
    private let facts = RuntimeInfo.facts()

    var body: some View {
        VStack(spacing: 16) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            Text("Verbinal")
                .font(.title)
                .fontWeight(.bold)

            Text("A CANFAR Science Portal Companion")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(RuntimeInfo.appVersion())")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("A native CANFAR companion for Search, Research, Storage,")
                Text("and FITS — with an optional AI agent that drives it for you.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            #if os(macOS)
            Button("Features…") {
                // Swap the single sheet host in place — no dismiss() first (that
                // races the binding-nil and can drop the next sheet; see WelcomeSheet).
                appState.activeSheet = .features
            }
            .buttonStyle(.borderless)
            .font(.caption)
            #endif

            // What a bug report needs, as text to paste.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.name) { fact in
                    Text("\(fact.name): \(fact.value)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)

            Button(copied ? "Copied" : "Copy Details") {
                PlatformClipboard.copy(RuntimeInfo.text(facts))
                copied = true
            }
            .font(.caption)
            .help("Copy these details, for a bug report")

            HStack(spacing: 16) {
                Link("verbinal.com", destination: AppLinks.website)
                Link("Report a Problem", destination: AppLinks.newIssue)
            }
            .font(.caption)

            Button(LegalText.document(for: locale).termsLink) {
                showTerms = true
            }
            .buttonStyle(.borderless)
            .opens("Terms of Use")
            .font(.caption)

            Divider()
                .frame(width: 200)

            Text("\u{00A9} 2026 Serhii Zautkin")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Close this dialog (⎋)")
        }
        .padding(32)
        .sheetFrame(width: 400)
        .uiPresented("Terms of Use", .sheet, isPresented: $showTerms)
        .sheet(isPresented: $showTerms) {
            LegalDocumentSheet()
        }
    }
}
