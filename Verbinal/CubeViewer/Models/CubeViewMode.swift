// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The two linked cube-viewing modes. Slice is the quantitative native-resolution
/// channel view; volume is the GPU ray-marched 3D view. Both share one
/// `CubeViewerModel` and the same normalization contract.
enum CubeViewMode: String, CaseIterable, Identifiable {
    case slice
    case volume

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slice: return "Slice"
        case .volume: return "Volume"
        }
    }

    var systemImage: String {
        switch self {
        case .slice: return "square.stack.3d.up.fill"
        case .volume: return "cube.transparent.fill"
        }
    }
}

/// Constants shared between the volume renderer's export snapshot and the SwiftUI
/// axis-caption overlay — kept in one place so the two can't drift apart.
enum CubeViewerConstants {
    /// Camera pull-back applied for export snapshots (adds figure margin around
    /// the box). `CubeAxisCaptions` must use the same value so labels stay aligned.
    static let exportDistanceScale: Float = 1.3
    /// Pixel size of the GPU export snapshot.
    static let exportWidth = 1400
    static let exportHeight = 1050
}
