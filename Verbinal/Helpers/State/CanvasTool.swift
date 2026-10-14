// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a press-and-drag on a viewer's image does (plan 38): pan it, select
/// an area of it for a figure, or draw a mark — one at a time, by
/// construction, so two tools never both claim a press. The same for the
/// FITS image and the cube slice; Esc goes back to panning.
enum CanvasTool: String, Codable, Equatable, Sendable {
    case pan, selectArea, draw
}
