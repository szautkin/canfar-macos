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

/// The Terms content (``LegalText``) as a plain, structured column — no
/// ScrollView of its own, so callers control scrolling. Extracted so the iOS
/// gate can prepend a hero and add footer clearance while keeping exactly one
/// scroll view per screen. Localized via the app's `\.locale` (English /
/// French).
private struct LegalDocumentBody: View {
    let doc: LegalText.Document
    /// Extra bottom padding so the last clause can scroll clear of an
    /// overlaid footer bar (used by the iOS gate).
    var bottomInset: CGFloat = 0

    var body: some View {
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
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// Scrollable rendering of the localized Terms. Identical on macOS and iOS;
/// used by the macOS gate/viewer and the iOS viewer. (The iOS gate renders
/// `LegalDocumentBody` directly inside its own scroll view.)
struct LegalDocumentView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            LegalDocumentBody(doc: LegalText.document(for: locale))
        }
    }
}

// MARK: - First-launch acceptance gate

/// Blocking acceptance gate shown over the app on first launch (and whenever
/// the Terms version changes). The user must explicitly agree to continue.
///
/// BLOCKING CONTRACT (load-bearing — do not regress in a refactor): presented
/// by `ContentView` as a non-dismissible `ZStack` overlay over an OPAQUE
/// backdrop; there is no Done/Close/back affordance and (on iOS) no navigation
/// toolbar; `.accessibilityAddTraits(.isModal)` traps VoiceOver inside the
/// gate; the ONLY exit is `service.accept()` flipping `hasAcceptedCurrent`.
struct LegalAgreementGate: View {
    let service: LegalAgreementService
    @Environment(\.locale) private var locale
    @State private var agreed = false
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    var body: some View {
        let doc = LegalText.document(for: locale)
        #if os(macOS)
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
                        Button(doc.quitButton) {
                            NSApplication.shared.terminate(nil)
                        }
                        .keyboardShortcut("q", modifiers: .command)
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
        #else
        iOSGate(doc)
        #endif
    }

    #if !os(macOS)
    private var isRegular: Bool { hSize == .regular }
    /// Cap the readable column on iPad; full width on iPhone.
    private var contentMaxWidth: CGFloat { isRegular ? 620 : .infinity }

    @ViewBuilder
    private func iOSGate(_ doc: LegalText.Document) -> some View {
        ZStack {
            // OPAQUE backdrop absorbs every tap → fully blocking. Keep opaque
            // (not a dimmed scrim) on both iPhone and iPad.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Hero — scrolls away with the content (large-title feel).
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle)                 // scales with Dynamic Type, bounded
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(doc.acceptHeadline)
                            .font(isRegular ? .title.bold() : .title2.bold())
                            .multilineTextAlignment(.center)
                        Text(doc.acceptSubhead)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    Divider()

                    LegalDocumentBody(doc: doc, bottomInset: 24)
                }
                .frame(maxWidth: contentMaxWidth, alignment: .leading)  // cap column on iPad
                .frame(maxWidth: .infinity)                             // center the capped column
                .padding(.horizontal, isRegular ? 24 : 0)              // iPad gutter
            }
            .scrollBounceBehavior(.basedOnSize)         // no bounce when terms are short
            .safeAreaInset(edge: .bottom) { footerBar(doc) }
        }
        // Trap VoiceOver inside the gate — the overlay is not a real modal
        // presentation, so this is required for the blocking guarantee.
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func footerBar(_ doc: LegalText.Document) -> some View {
        VStack(spacing: 14) {
            Toggle(isOn: $agreed) {
                Text(doc.agreeToggle)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)   // wrap fully at AX sizes
            }
            .toggleStyle(.switch)

            Button {
                service.accept()
            } label: {
                Text(doc.agreeButton)
                    .frame(maxWidth: .infinity)                     // full-width CTA
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!agreed)                                      // gated on the toggle only
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: contentMaxWidth)   // cap inner content on iPad…
        .frame(maxWidth: .infinity)         // …but center it (the bar spans edge-to-edge)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)                   // translucent material; scrolled text peeks under
    }
    #endif
}

// MARK: - In-app viewer (About / Account link)

/// Read-only presentation of the Terms for the About (macOS) / Account (iOS)
/// links. Unlike the gate, this is freely dismissible.
struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        let doc = LegalText.document(for: locale)
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(doc.title)
                    .font(.headline)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(doc.plainText, forType: .string)
                } label: {
                    Label(doc.copyButton, systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button(doc.doneButton) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            LegalDocumentView()
        }
        .frame(width: 560, height: 640)
        #else
        NavigationStack {
            LegalDocumentView()
                .navigationTitle(doc.title)
                .navigationBarTitleDisplayMode(.inline)   // long bilingual title → inline, no truncation
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            PlatformClipboard.copy(doc.plainText)
                        } label: {
                            Label(doc.copyButton, systemImage: "doc.on.doc")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(doc.doneButton) { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
