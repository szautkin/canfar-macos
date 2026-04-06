// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Kernel execution state.
enum KernelState: Equatable {
    case stopped
    case starting
    case idle
    case busy
    case error(String)
}

/// A single cell output from the kernel.
struct CellOutput: Identifiable {
    let id = UUID()
    let type: OutputType
    let text: String
    let imageBase64: String?

    enum OutputType {
        case stdout
        case stderr
        case result
        case error
        case image
    }
}

/// A notebook cell (code or markdown).
@Observable
final class NotebookCell: Identifiable {
    let id = UUID()
    var cellType: CellType
    var source: String
    var outputs: [CellOutput] = []
    var executionCount: Int?
    var isExecuting = false
    var isOutputCollapsed = false

    enum CellType: String { case code, markdown }

    init(cellType: CellType = .code, source: String = "") {
        self.cellType = cellType
        self.source = source
    }

    var executionLabel: String {
        if isExecuting { return "[*]" }
        if let count = executionCount { return "[\(count)]" }
        return "[ ]"
    }
}
