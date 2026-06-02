// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Document renderer (reused by the gate and the in-app viewer)

/// Scrollable rendering of the localized Terms (``LegalText``). No Markdown
/// engine — plain structured text, identical on macOS and iOS. Localized via the
/// app's `\.locale` environment (English / French).
struct LegalDocumentView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        let doc = LegalText.document(for: locale)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(doc.title)
                    .font(.title2.bold())
                Text(doc.lastUpdatedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(doc.intro)
                    .font(.callout)
                ForEach(doc.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.heading)
                            .font(.headline)
                        Text(section.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

// MARK: - First-launch acceptance gate

/// Blocking acceptance gate shown over the app on first launch (and whenever the
/// Terms version changes). The user must explicitly agree to continue.
struct LegalAgreementGate: View {
    let service: LegalAgreementService
    @Environment(\.locale) private var locale
    @State private var agreed = false

    var body: some View {
        let doc = LegalText.document(for: locale)
        ZStack {
            // Opaque backdrop blocks interaction with the app beneath.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text(doc.acceptHeadline)
                        .font(.title3.bold())
                    Text(doc.acceptSubhead)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()

                Divider()

                LegalDocumentView()

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $agreed) {
                        Text(doc.agreeToggle)
                            .font(.callout)
                    }
                    HStack {
                        #if os(macOS)
                        Button(doc.quitButton) {
                            NSApplication.shared.terminate(nil)
                        }
                        .keyboardShortcut("q", modifiers: .command)
                        #endif
                        Spacer()
                        Button(doc.agreeButton) {
                            service.accept()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!agreed)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
            }
            .frame(maxWidth: 720, maxHeight: 760)
            .padding()
        }
    }
}

// MARK: - In-app viewer (About / Account link)

/// Read-only presentation of the Terms for the About (macOS) / Account (iOS) links.
struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        let doc = LegalText.document(for: locale)
        VStack(spacing: 0) {
            HStack {
                Text(doc.title)
                    .font(.headline)
                Spacer()
                #if os(macOS)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(doc.plainText, forType: .string)
                } label: {
                    Label(doc.copyButton, systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                #endif
                Button(doc.doneButton) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            LegalDocumentView()
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
    }
}
