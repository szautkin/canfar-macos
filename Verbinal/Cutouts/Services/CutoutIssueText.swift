// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

extension CutoutIssue {
    /// The issue in the person's language, for the editor. An agent reads `message`.
    var localizedMessage: String {
        switch self {
        case .nothingToCut: return String(localized: "Choose a region (or a band) to cut; with neither, the whole file would come back.")
        case .region(let problem):
            switch problem {
            case .notANumber: return String(localized: "The position and size have to be numbers.")
            case .decOutOfRange: return String(localized: "Dec has to be between −90° and +90°.")
            case .sizeNotPositive: return String(localized: "The size has to be greater than zero.")
            case .tooLarge: return String(localized: "That region is larger than any cutout can be.")
            case .tooFewVertices: return String(localized: "A polygon needs at least three corners.")
            case .degenerate: return String(localized: "Those corners enclose no area.")
            }
        case .noRegionShape: return String(localized: "This file cannot be cut to that shape.")
        case .outsideFootprint: return String(localized: "That region is outside this file's footprint.")
        case .partlyOutsideFootprint: return String(localized: "Part of that region is outside the footprint; the cutout will be trimmed to it.")
        case .noBand: return String(localized: "This file cannot be cut by wavelength.")
        case .bandOrder: return String(localized: "The shortest wavelength has to be below the longest.")
        case .bandOutside: return String(localized: "That wavelength range is outside this file's.")
        case .bandPartial: return String(localized: "Part of that wavelength range is outside this file's; the cutout will be trimmed to it.")
        case .noTime: return String(localized: "This file cannot be cut by time.")
        case .timeOrder: return String(localized: "The start has to be before the end.")
        case .timeOutside: return String(localized: "That time range is outside this file's.")
        case .timePartial: return String(localized: "Part of that time range is outside this file's; the cutout will be trimmed to it.")
        case .noPol: return String(localized: "This file cannot be cut by polarization.")
        case .polUnknown(let state, let available):
            return String(localized: "This file has no \(state) polarization; it has \(available.joined(separator: ", ")).")
        case .unknownImage(let name, let available):
            return String(localized: "This file has no image \(name); it has \(available.joined(separator: ", ")).")
        case .noImageChoice:
            return String(localized: "This way of cutting cannot choose among the file's images; it keeps every image the region falls on.")
        case .unreadable(let why):
            return String(localized: "The file on this computer could not be read: \(why)")
        }
    }
}
