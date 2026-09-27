// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a person can ask for about one mark. Each has a tool behind it
/// for an assistant (update_annotation, copy_to_clipboard, select_annotation,
/// run_search, export_annotations, remove_annotation).
enum MarkCommand: Hashable, Sendable {
    case editLabel
    case copyPosition
    case centre
    case searchHere
    case export(MarkExport.Format)
    case delete
}

/// A viewer that answers a mark's menu. The canvas and the Marks list
/// point at the same marks, so both ask the viewer — one menu, not two to
/// keep in step.
@MainActor
protocol MarkCommandHost {
    /// The mark has a sky position: its own, or through the image's WCS.
    func canLocateOnSky(_ mark: Mark) -> Bool
    func perform(_ command: MarkCommand, on mark: Mark)
    /// Save the marks on screen to a file.
    func export(_ format: MarkExport.Format)
}

/// A mark's menu, as data: the canvas renders it as an NSMenu, the list as
/// SwiftUI buttons.
struct MarkMenuItem: Identifiable, Equatable {
    let command: MarkCommand
    let title: String
    let systemImage: String
    var enabled = true
    /// Why it is greyed — a greyed item that does not say why reads as broken.
    var disabledReason: String?

    var id: MarkCommand { command }
    /// Delete is set apart, so a slipped click lands on Centre, not on it.
    var destructive: Bool { command == .delete }

    @MainActor
    static func items(for mark: Mark, host: MarkCommandHost) -> [MarkMenuItem] {
        let onSky = host.canLocateOnSky(mark)
        return [
            MarkMenuItem(command: .editLabel, title: String(localized: "Edit Label"), systemImage: "character.cursor.ibeam"),
            MarkMenuItem(command: .copyPosition, title: String(localized: "Copy Position"), systemImage: "doc.on.doc"),
            MarkMenuItem(command: .centre, title: String(localized: "Centre on Mark"), systemImage: "scope"),
            MarkMenuItem(command: .searchHere, title: String(localized: "Search Here"), systemImage: "magnifyingglass",
                         enabled: onSky, disabledReason: onSky ? nil : String(localized: "This image has no sky coordinates")),
            MarkMenuItem(command: .export(.ds9), title: String(localized: "Export Marks as DS9 Regions…"),
                         systemImage: "square.and.arrow.up"),
            MarkMenuItem(command: .export(.json), title: String(localized: "Export Marks as JSON…"),
                         systemImage: "square.and.arrow.up"),
            MarkMenuItem(command: .delete, title: String(localized: "Delete Mark"), systemImage: "trash"),
        ]
    }
}
