// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Why a registry search found nothing to show, in words that say what to do.
enum RegistrySearchError: LocalizedError, Equatable {
    case noHost
    case emptyQuery
    case unreachable(String)
    case rejected
    case status(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noHost: return String(localized: "No registry host is set — see Settings ▸ Image Discovery.")
        case .emptyQuery: return String(localized: "Type part of an image's name to search for.")
        case .unreachable(let why): return String(localized: "Could not reach the registry: \(why)")
        // The fix is specific, and the CADC password is the wrong answer often enough to say so.
        case .rejected: return String(localized: "The registry refused these credentials. Use your Harbor CLI secret, not your CADC password.")
        case .status(let code): return String(localized: "The registry answered HTTP \(code).")
        case .unreadable(let why): return String(localized: "Could not read the registry's answer: \(why)")
        }
    }
}

/// Searching the container registry behind the platform — only when asked.
///
/// Nothing here runs on a timer or at start-up: enumerating a Harbor
/// instance to fill a card would be a great deal of traffic on a shared
/// service to answer a question nobody asked.
///
/// Harbor's own API rather than the OCI distribution API, for its LABELS:
/// `/v2/_catalog` and `tags/list` enumerate any registry but report no
/// labels without pulling each image's config, and the labels are what
/// say whether an image is a notebook or a CARTA session.
struct RegistrySearch: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Repositories one search opens. Harbor returns hundreds for a short
    /// term; past a couple of dozen the person is re-typing, not reading.
    static let maxRepositories = 24
    /// Read at once — not fifty connections to a shared service on one click.
    static let concurrentReads = 4
    /// Tags per repository, newest first: two hundred tags is a build history.
    static let artifactsPerRepository = 10

    let fetch: Fetch

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.fetch = fetch
    }

    /// Images in `host` whose repository matches `query`, by reference.
    /// `basic` is `base64(user:secret)`; a public project answers without it.
    func search(host rawHost: String, query rawQuery: String, basic: String?) async throws(RegistrySearchError) -> [RegistryImage] {
        let host = RegistryImage.normalized(rawHost).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { throw .noHost }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty is refused rather than read as "everything" — the whole-registry download this avoids.
        guard !query.isEmpty else { throw .emptyQuery }

        let found: SearchResponse = try await json(Self.searchURL(host: host, query: query), basic: basic)
        let repositories = Array((found.repository ?? []).prefix(Self.maxRepositories))

        var images: [RegistryImage] = []
        for start in stride(from: 0, to: repositories.count, by: Self.concurrentReads) {
            let chunk = repositories[start..<min(start + Self.concurrentReads, repositories.count)]
            images += await withTaskGroup(of: [RegistryImage].self) { group in
                for repository in chunk {
                    group.addTask {
                        let project = repository.project ?? ""
                        let name = repository.name ?? ""
                        // One the person cannot see is skipped, not fatal: a search
                        // across projects routinely includes one.
                        guard let url = Self.artifactsURL(host: host, project: project, repository: name),
                              let artifacts: [Artifact] = try? await json(url, basic: basic) else { return [] }
                        return Self.images(host: host, repository: name, artifacts: artifacts)
                    }
                }
                return await group.reduce(into: []) { $0 += $1 }
            }
        }
        var seen = Set<String>()
        return images.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    // MARK: - Harbor's addresses and answers

    static func searchURL(host: String, query: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/api/v2.0/search"
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts.url
    }

    /// One repository's artifacts. The repository is DOUBLE-encoded: Harbor
    /// addresses a nested one (`skaha/base/astro`) as one path segment, so
    /// its `/` must survive the proxy's decode still encoded.
    static func artifactsURL(host: String, project: String, repository: String) -> URL? {
        let bare = repository.hasPrefix(project + "/") ? String(repository.dropFirst(project.count + 1)) : repository
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let once = bare.addingPercentEncoding(withAllowedCharacters: unreserved),
              let twice = once.addingPercentEncoding(withAllowedCharacters: unreserved),
              let projectPart = project.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://\(host)/api/v2.0/projects/\(projectPart)/repositories/\(twice)/artifacts"
                   + "?with_label=true&page_size=\(artifactsPerRepository)&page=1")
    }

    /// A repository's artifacts as launchable references. An untagged one is
    /// skipped: only a digest addresses it, and the launch form takes tags.
    static func images(host: String, repository: String, artifacts: [Artifact]) -> [RegistryImage] {
        artifacts.flatMap { artifact in
            let labels = (artifact.labels ?? []).compactMap(\.name)
            return (artifact.tags ?? []).compactMap(\.name)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { RegistryImage(id: "\(host)/\(repository):\($0)", labels: labels) }
        }
    }

    struct SearchResponse: Decodable {
        let repository: [Repository]?
    }

    struct Repository: Decodable {
        let project: String?
        /// `project/name`, where `name` may itself contain `/`.
        let name: String?

        enum CodingKeys: String, CodingKey {
            case project = "project_name"
            case name = "repository_name"
        }
    }

    struct Artifact: Decodable {
        let tags: [Named]?
        let labels: [Named]?
    }

    struct Named: Decodable {
        let name: String?
    }

    // MARK: - The request

    private func json<T: Decodable>(_ url: URL?, basic: String?) async throws(RegistrySearchError) -> T {
        guard let url else { throw .noHost }
        var request = URLRequest(url: url, timeoutInterval: RequestTimeout.lookup)
        if let basic, !basic.isEmpty { request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        if code == 401 || code == 403 { throw .rejected }
        guard (200..<300).contains(code) else { throw .status(code) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }
}
