// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Where Research's records are kept on this Mac, and the person's moves
/// between their file and the database (plan 36 5.1) — theirs alone: no
/// launch moves them, and no assistant can.
struct ResearchDataMenu: View {
    let store: ObservationStore

    /// The move the person asked for, until they confirm it.
    @State private var asked: ResearchRecords.Place?
    /// What the move came to.
    @State private var outcome: String?

    var body: some View {
        Menu {
            Section(store.recordsPlace == .file
                    ? String(localized: "Research's records are kept in a file")
                    : String(localized: "Research's records are kept in the database")) {
                if store.recordsPlace == .file {
                    Button("Move into the Database…") { asked = .database }
                } else {
                    Button("Move Back to a File…") { asked = .file }
                }
            }
        } label: {
            Image(systemName: "cylinder.split.1x2")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where Research's records are kept on this Mac")
        .accessibilityLabel("Research data")
        .uiPresented("Move Research?", .confirmation, item: $asked)
        .confirmationDialog(asked == .database ? String(localized: "Move Research into the database?")
                                               : String(localized: "Move Research back to a file?"),
                            isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } })) {
            Button("Move") { move() }
        } message: {
            if asked == .database {
                Text("Verbinal copies Research's file to a dated backup, writes its \(store.observations.count) records into its database and checks each one. If any record does not match, nothing moves. Your files and notes are not touched, and you can move Research back to a file.")
            } else {
                Text("Verbinal writes the \(store.observations.count) records into Research's file, reads them back and checks each one, then keeps them in the file again.")
            }
        }
        .uiPresented("Research Records", .alert, isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } }))
        .alert("Research Records", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) { outcome = nil }
        } message: {
            Text(outcome ?? "")
        }
    }

    private func move() {
        guard let place = asked else { return }
        asked = nil
        do {
            if place == .database {
                let moved = try store.moveIntoDatabase()
                outcome = moved.backup.map {
                    String(localized: "Moved \(moved.records) records into the database. The file's backup is \($0), beside it.")
                } ?? String(localized: "Moved \(moved.records) records into the database.")
            } else {
                let moved = try store.moveBackToFile()
                outcome = String(localized: "Moved \(moved.records) records back into their file.")
            }
        } catch {
            outcome = error.localizedDescription
        }
    }
}
