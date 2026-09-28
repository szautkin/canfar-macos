// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics

/// The Portal's cards.
enum PortalCard: CaseIterable, Hashable, Sendable {
    case platformLoad, storage, batchJobs, sessions, images, recentLaunches
}

/// Where a card sits on the Portal's grid.
struct PortalCell: Equatable, Hashable, Sendable {
    let row: Int
    let column: Int
    let span: Int
}

/// Where the Portal's cards go — Verbinal for Linux's arrangement, as
/// Windows has it: platform load, storage and batch jobs across the top,
/// active sessions the full width, then CANFAR images beside recent
/// launches; one column below `breakpoint`. The launch form is not a card:
/// Launch Session on Active Sessions opens it in a sheet.
enum PortalLayout {
    static let columns = 3
    /// Narrower than this, the cards stack.
    static let breakpoint: CGFloat = 1000
    /// Between columns and between rows.
    static let spacing: CGFloat = 16

    /// A card's width when it spans `span` of the columns across `width`:
    /// the columns share the width equally, spacing between them. Given,
    /// not left to the grid to work out from the cards' contents — which let
    /// one column take the whole window and push the others off the edge.
    static func width(ofSpan span: Int, in width: CGFloat) -> CGFloat {
        let column = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let spanned = min(max(span, 1), columns)
        return column * CGFloat(spanned) + spacing * CGFloat(spanned - 1)
    }

    static let wide: [PortalCard: PortalCell] = [
        .platformLoad: PortalCell(row: 0, column: 0, span: 1),
        .storage: PortalCell(row: 0, column: 1, span: 1),
        .batchJobs: PortalCell(row: 0, column: 2, span: 1),
        .sessions: PortalCell(row: 1, column: 0, span: 3),
        .images: PortalCell(row: 2, column: 0, span: 2),
        .recentLaunches: PortalCell(row: 2, column: 2, span: 1),
    ]

    /// One column, in the same order as wide.
    static let narrow: [PortalCard: PortalCell] = Dictionary(uniqueKeysWithValues:
        PortalCard.allCases.enumerated().map { ($1, PortalCell(row: $0, column: 0, span: columns)) })

    static func arrangement(forWidth width: CGFloat) -> [PortalCard: PortalCell] {
        width >= breakpoint ? wide : narrow
    }

    /// The arrangement row by row, each row's cards left to right. A card
    /// not `present` keeps its place in a row others share — the next card
    /// must not slide into its column — and a row with none present goes.
    static func rows(_ arrangement: [PortalCard: PortalCell],
                     present: Set<PortalCard> = Set(PortalCard.allCases)) -> [[(card: PortalCard, cell: PortalCell)]] {
        Dictionary(grouping: arrangement.map { (card: $0.key, cell: $0.value) }, by: \.cell.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.cell.column < $1.cell.column } }
            .filter { row in row.contains { present.contains($0.card) } }
    }
}
