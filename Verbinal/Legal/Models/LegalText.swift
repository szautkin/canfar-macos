// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// ─────────────────────────────────────────────────────────────────────────────
// ⚠️  TEMPLATE — NOT LEGAL ADVICE.
//
// This text is an engineering-drafted starting point so the in-app acceptance
// gate is functional. It has NOT been reviewed by a lawyer. Before shipping,
// have qualified counsel review it for enforceability in your jurisdiction
// (warranty disclaimers and liability caps are limited by some consumer-
// protection regimes, e.g. parts of the EU/UK and certain US states), and
// replace every [BRACKETED] placeholder. When the text changes materially,
// bump `version` so all users are re-prompted to accept.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

/// The Terms of Use / disclaimer document shown by the first-launch acceptance
/// gate and the in-app viewer. Plain structured text so it renders identically
/// on macOS and iOS without a Markdown engine.
enum LegalText {

    /// Acceptance version. Bump on any material change to re-prompt users.
    static let version = 1

    static let title = "Terms of Use & Disclaimers"
    static let lastUpdated = "June 2, 2026"
    static let developer = "Serhii Zautkin"      // [confirm: individual vs. entity name]
    static let appName = "Verbinal"

    static let intro = """
    Please read these Terms of Use ("Terms") carefully before using \(appName) (the \
    "App"). By tapping "I Agree" — or by installing or using the App — you accept these \
    Terms. If you do not agree, do not use the App.
    """

    struct Section: Identifiable {
        let heading: String
        let body: String
        var id: String { heading }
    }

    static let sections: [Section] = [
        Section(
            heading: "1. Acceptance & License",
            body: """
            \(appName) is provided by \(developer) ("we", "us"). Subject to these Terms, \
            we grant you a personal, non-exclusive, non-transferable, revocable license to \
            use the App on devices you own or control, for your own non-commercial or \
            internal research use. Where the App is obtained through Apple's App Store, \
            Apple's Licensed Application End User License Agreement also applies and, to the \
            extent it conflicts with these Terms, Apple's minimum terms govern that \
            distribution.
            """
        ),
        Section(
            heading: "2. No Warranty — Provided \u{201C}AS IS\u{201D}",
            body: """
            THE APP IS PROVIDED \u{201C}AS IS\u{201D} AND \u{201C}AS AVAILABLE\u{201D}, WITHOUT WARRANTY OF ANY KIND, \
            WHETHER EXPRESS, IMPLIED, OR STATUTORY. TO THE FULLEST EXTENT PERMITTED BY LAW, \
            WE DISCLAIM ALL WARRANTIES, INCLUDING THE IMPLIED WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE, TITLE, NON-INFRINGEMENT, AND ANY WARRANTY THAT \
            THE APP WILL BE UNINTERRUPTED, ERROR-FREE, SECURE, OR THAT DATA WILL BE ACCURATE, \
            PRESERVED, OR RECOVERABLE. You use the App at your own risk.
            """
        ),
        Section(
            heading: "3. Your Data & Backups",
            body: """
            The App stores your content — including research notes, ratings, tags, saved \
            queries, downloaded files, and preferences — locally on your device. We do not \
            operate a backup or sync service for this content. Software can contain defects \
            that corrupt, overwrite, or delete data, and operating-system, hardware, or \
            storage failures can do the same. YOU ARE SOLELY RESPONSIBLE FOR MAINTAINING \
            INDEPENDENT BACKUPS of any data you value. Use the App's export feature and your \
            own backup system regularly. We are not responsible for any loss, corruption, or \
            inaccessibility of your data.
            """
        ),
        Section(
            heading: "4. Limitation of Liability",
            body: """
            TO THE FULLEST EXTENT PERMITTED BY LAW, IN NO EVENT WILL WE BE LIABLE FOR ANY \
            INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR PUNITIVE DAMAGES, OR \
            FOR ANY LOSS OF DATA, LOSS OF RESEARCH, LOST PROFITS, OR LOSS OF GOODWILL, \
            ARISING OUT OF OR RELATED TO YOUR USE OF (OR INABILITY TO USE) THE APP, EVEN IF \
            ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. OUR TOTAL AGGREGATE LIABILITY FOR ALL \
            CLAIMS RELATING TO THE APP WILL NOT EXCEED THE GREATER OF (a) THE AMOUNT YOU PAID \
            FOR THE APP IN THE 12 MONTHS BEFORE THE CLAIM, OR (b) USD $10. Some jurisdictions \
            do not allow certain exclusions or limitations, so some of the above may not \
            apply to you; in that case our liability is limited to the smallest extent \
            permitted by law.
            """
        ),
        Section(
            heading: "5. Third-Party Services & Data",
            body: """
            The App connects, at your direction, to third-party services that we neither own \
            nor control — including the Canadian Astronomy Data Centre (CADC) / CANFAR, \
            Anthropic's Claude services, and any container image registries you configure. \
            Your use of those services is governed by their own terms and privacy policies, \
            and you are responsible for your own accounts and credentials with them. We do \
            not warrant the availability, accuracy, completeness, or scientific correctness \
            of any data retrieved from third-party sources, and we are not responsible for \
            their acts, omissions, content, or charges.
            """
        ),
        Section(
            heading: "6. AI & Automated Features",
            body: """
            The App includes AI-assisted and automated agent features that may generate \
            suggestions, queries, or actions. These outputs can be incomplete or incorrect \
            and may change data or interact with services on your behalf. They are not \
            professional, scientific, or research advice. You are responsible for reviewing \
            any AI-generated or automated action before relying on it, and for confirming \
            results against authoritative sources.
            """
        ),
        Section(
            heading: "7. Acceptable Use",
            body: """
            You agree to use the App lawfully and in accordance with the terms of any \
            connected service; not to misuse, overload, or attempt to gain unauthorized \
            access to any service; and not to use the App to infringe the rights of others \
            or to store or transmit unlawful content.
            """
        ),
        Section(
            heading: "8. Changes, Termination & Governing Law",
            body: """
            We may update the App and these Terms; material changes will be presented for \
            your acceptance. You may stop using the App at any time by deleting it. These \
            Terms are governed by the laws of [GOVERNING-LAW JURISDICTION], without regard to \
            its conflict-of-laws rules, and you agree to the exclusive jurisdiction of its \
            courts, except where applicable law gives you the right to bring claims \
            elsewhere.
            """
        ),
        Section(
            heading: "9. Contact",
            body: """
            Questions about these Terms: [CONTACT EMAIL]. If any provision is held \
            unenforceable, the remaining provisions remain in effect.
            """
        ),
    ]

    /// Flattened plain-text form (used for copy/share and as an accessibility fallback).
    static var plainText: String {
        var out = "\(title)\nLast updated: \(lastUpdated)\n\n\(intro)\n\n"
        for s in sections {
            out += "\(s.heading)\n\(s.body)\n\n"
        }
        return out
    }
}
