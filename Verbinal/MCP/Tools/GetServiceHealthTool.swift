// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Probe the upstream services Verbinal depends on and return a
/// per-service status snapshot. Closes the 2026-05-15 QA finding
/// (cross-app #4 / joint #1): "A `verbinal-canfar:get_service_health`
/// endpoint feeding a Thought `#blocker` tag would be the right
/// pattern — automated pipelines could pause cleanly rather than
/// retry-and-fail when the VizieR proxy is down."
///
/// v1 is host-reachability: each entry reports whether a known
/// availability URL responded within a 5-second budget. This
/// answers "is the service reachable from my Mac right now?" but
/// doesn't speak to "is the service correct" — that distinction
/// needs deeper probes per service (e.g. a known-good cone search)
/// and is queued for v2.
struct GetServiceHealthTool: JSONReadTool {

    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let services: [Service]
        /// Wall-clock when the probe started, ISO-8601 UTC.
        let probeStartedISO: String

        struct Service: Encodable, Sendable {
            /// Stable canonical name. Agents key on this for
            /// "compare last call's snapshot to this one."
            let name: String
            /// Hostname the probe contacted. Helpful for users
            /// reading the response who want to know which mirror
            /// answered.
            let host: String
            /// `"ok"` — the host returned a response (any 2xx/3xx/4xx
            ///   status). `/availability` may not exist on every
            ///   service; a 404 still means the host is reachable.
            /// `"degraded"` — host returned 5xx (upstream is up but
            ///   serving errors).
            /// `"down"` — DNS / connect / TLS / timeout. The host is
            ///   unreachable from this Mac right now.
            let status: String
            /// Round-trip in milliseconds. `nil` only for the
            /// `"down"` cases that didn't complete.
            let latencyMs: Int?
            /// Optional one-liner: HTTP status code, error message,
            /// or "(host reachable but /availability not
            /// implemented)" when we got a 4xx.
            let message: String?
        }
    }

    var toolTimeoutSeconds: TimeInterval { 30 }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_service_health",
        description: "Probe the upstream services Verbinal depends on (CADC TAP, VOSpace, Skaha, VizieR mirrors) and return a per-service reachability snapshot. Use BEFORE long pipelines to decide whether to proceed or pause: when `vizier-cds-unistra` is `down` your cone searches will fail; when `skaha` is `down` no Skaha session will launch. Each entry's `status` is `\"ok\"` (host responded, any status), `\"degraded\"` (host returned 5xx), or `\"down\"` (DNS/connect/TLS/timeout). v1 is host reachability, not service correctness — a green `ok` doesn't guarantee the service will answer your specific query, but a `down` reliably means \"don't bother trying.\"",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// Closure that runs the full probe set in parallel. The
    /// wireup layer plugs in the real network probe; tests
    /// inject a synthetic closure with pre-canned results.
    let probe: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await probe()
    }

    // MARK: - Canonical endpoint list

    /// One entry to probe per service. Probe URL is canonical
    /// `/availability` (IVOA convention) when the service
    /// implements it, otherwise the service root — any HTTP
    /// response is "the host is up." Hostnames are split out
    /// so the response can surface them without re-parsing the
    /// URL.
    struct Endpoint: Sendable, Equatable {
        let name: String
        let host: String
        let url: String
    }

    /// Canonical service set. Add new services here; tests
    /// will catch the count drift via
    /// `testEndpointSetCovers...`.
    static let canonicalEndpoints: [Endpoint] = [
        Endpoint(
            name: "cadc-tap",
            host: "ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
            url: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/availability"
        ),
        Endpoint(
            name: "cadc-resolver",
            host: "ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
            url: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/cadc-target-resolver/availability"
        ),
        Endpoint(
            name: "vospace",
            host: "ws-uv.canfar.net",
            url: "https://ws-uv.canfar.net/arc/availability"
        ),
        Endpoint(
            name: "skaha",
            host: "ws-uv.canfar.net",
            url: "https://ws-uv.canfar.net/skaha/availability"
        ),
        Endpoint(
            name: "vizier-cds-unistra",
            host: "tap.cds.unistra.fr",
            url: "https://tap.cds.unistra.fr/tap/availability"
        ),
        Endpoint(
            name: "vizier-cds-u-strasbg",
            host: "tapvizier.u-strasbg.fr",
            url: "https://tapvizier.u-strasbg.fr/TAPVizieR/tap/availability"
        ),
        Endpoint(
            name: "vizier-esac",
            host: "tapvizier.esac.esa.int",
            url: "https://tapvizier.esac.esa.int/TAPVizieR/tap/availability"
        ),
        Endpoint(
            name: "vizier-china-vo",
            host: "vizier.china-vo.org",
            url: "http://vizier.china-vo.org/tap/availability"
        ),
    ]

    // MARK: - Real-network probe (used by the wireup)

    /// Run every canonical probe in parallel and collect results.
    /// 5-second per-probe budget; the outer `toolTimeoutSeconds`
    /// is the upper bound on the whole call.
    ///
    /// Lives on the tool type (not the wireup) so it stays close
    /// to the canonical endpoint list and tests can spot-check
    /// individual probes without setting up an AppState.
    static func runCanonicalProbes(
        endpoints: [Endpoint] = canonicalEndpoints,
        perProbeBudget: TimeInterval = 5,
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let startISO = iso.string(from: now)
        let services = await withTaskGroup(of: Output.Service.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    await probeOne(
                        endpoint: endpoint,
                        budget: perProbeBudget,
                        session: session
                    )
                }
            }
            var collected: [Output.Service] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.name < $1.name }
        }
        return Output(services: services, probeStartedISO: startISO)
    }

    /// Single-endpoint probe. Returns the typed `Service`
    /// envelope; never throws.
    private static func probeOne(
        endpoint: Endpoint,
        budget: TimeInterval,
        session: URLSession
    ) async -> Output.Service {
        guard let url = URL(string: endpoint.url) else {
            return Output.Service(
                name: endpoint.name, host: endpoint.host,
                status: "down", latencyMs: nil,
                message: "invalid url: \(endpoint.url)"
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = budget
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return Output.Service(
                    name: endpoint.name, host: endpoint.host,
                    status: "down", latencyMs: latencyMs,
                    message: "non-http response"
                )
            }
            return classify(
                name: endpoint.name, host: endpoint.host,
                statusCode: http.statusCode, latencyMs: latencyMs
            )
        } catch {
            return Output.Service(
                name: endpoint.name, host: endpoint.host,
                status: "down", latencyMs: nil,
                message: error.localizedDescription
            )
        }
    }

    /// Status code → status string. Pulled out as a pure
    /// function so tests can pin the classification rules
    /// without spinning a URLSession.
    static func classify(
        name: String, host: String, statusCode: Int, latencyMs: Int?
    ) -> Output.Service {
        switch statusCode {
        case 500...599:
            return Output.Service(
                name: name, host: host,
                status: "degraded", latencyMs: latencyMs,
                message: "HTTP \(statusCode)"
            )
        case 400...499:
            // 4xx: host reachable but /availability either
            // isn't implemented (404), needs auth we didn't
            // send (401/403), etc. We treat the host as "ok"
            // — what we care about is reachability — but
            // surface the code in the message so the user
            // sees why the probe path was unconventional.
            return Output.Service(
                name: name, host: host,
                status: "ok", latencyMs: latencyMs,
                message: "HTTP \(statusCode) — host reachable but /availability not implemented"
            )
        default:
            // 1xx/2xx/3xx — all "ok" with no message needed.
            return Output.Service(
                name: name, host: host,
                status: "ok", latencyMs: latencyMs,
                message: nil
            )
        }
    }
}
