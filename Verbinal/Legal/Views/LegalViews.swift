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

/// Scrollable rendering of ``LegalText``. No Markdown engine — plain structured
/// text so it renders identically on macOS and iOS.
struct LegalDocumentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(LegalText.title)
                    .font(.title2.bold())
                Text("Last updated: \(LegalText.lastUpdated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LegalText.intro)
                    .font(.callout)
                ForEach(LegalText.sections) { section in
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
    @State private var agreed = false

    var body: some View {
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
                    Text("Welcome to \(LegalText.appName)")
                        .font(.title3.bold())
                    Text("Please review and accept the Terms of Use to continue.")
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
                        Text("I have read and agree to the Terms of Use, including the disclaimer of warranties and the limitation of liability (including for data loss).")
                            .font(.callout)
                    }
                    HStack {
                        #if os(macOS)
                        Button("Quit") {
                            NSApplication.shared.terminate(nil)
                        }
                        .keyboardShortcut("q", modifiers: .command)
                        #endif
                        Spacer()
                        Button("I Agree") {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LegalText.title)
                    .font(.headline)
                Spacer()
                #if os(macOS)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(LegalText.plainText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                #endif
                Button("Done") { dismiss() }
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
