// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How a request to CADC or CANFAR failed, as NetworkClient says it.
public enum NetworkError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case httpError(Int, String)

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Authentication required"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
