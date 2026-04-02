// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Range Parsing

enum Operand: String {
    case equals
    case range
    case lessThan
    case greaterThan
    case lessThanEquals
    case greaterThanEquals
}

struct ParsedRange {
    var lower: Double?
    var upper: Double?
    var value: Double?
    var operand: Operand
}

struct ParsedRangeRaw {
    var lowerRaw: String?
    var upperRaw: String?
    var valueRaw: String?
    var operand: Operand
}

// MARK: - Resolver

enum ResolverValue: String, CaseIterable, Identifiable {
    case all = "ALL"
    case simbad = "SIMBAD"
    case ned = "NED"
    case vizier = "VIZIER"
    case none = "NONE"

    var id: String { rawValue }
}

// MARK: - Intent

enum IntentValue: String, CaseIterable, Identifiable {
    case any = ""
    case science = "science"
    case calibration = "calibration"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "Science and Calibration"
        case .science: return "Science only"
        case .calibration: return "Calibration only"
        }
    }
}

// MARK: - Date Presets

enum DatePresetValue: String, CaseIterable, Identifiable {
    case none = ""
    case past24Hours = "PAST_24_HOURS"
    case pastWeek = "PAST_WEEK"
    case pastMonth = "PAST_MONTH"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .past24Hours: return "Past 24 hours"
        case .pastWeek: return "Past week"
        case .pastMonth: return "Past month"
        }
    }
}

// MARK: - Date Parsing

enum DateFormat {
    case jd
    case mjd
    case iso
}

enum DateGranularity {
    case year, month, day, hour, minute, second, millisecond
}

struct ParsedDate {
    let date: Date
    let format: DateFormat
    let granularity: DateGranularity
}

// MARK: - Resolver Status

enum ResolverStatus: Equatable {
    case idle
    case resolving
    case resolved(ra: String, dec: String)
    case failed(String)
}
