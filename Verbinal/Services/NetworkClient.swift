// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

actor NetworkClient {
    private let session: URLSession
    private(set) var token: String?

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setToken(_ token: String?) {
        self.token = token
    }

    // MARK: - HTTP Methods

    func get(_ urlString: String, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "GET")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return try await execute(request)
    }

    func getText(_ urlString: String) async throws -> String {
        let (data, _) = try await get(urlString)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func getJSON<T: Decodable>(_ urlString: String, type: T.Type) async throws -> T {
        let (data, _) = try await get(urlString, accept: "application/json")
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    func post(
        _ urlString: String,
        formData: [String: String],
        headers: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = formData
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return try await execute(request)
    }

    func delete(_ urlString: String) async throws -> HTTPURLResponse {
        let request = try makeRequest(urlString, method: "DELETE")
        let (_, response) = try await execute(request)
        return response
    }

    // MARK: - Private

    private func makeRequest(_ urlString: String, method: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpError(httpResponse.statusCode, body)
        }
        return (data, httpResponse)
    }
}

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Authentication required"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
