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
        /// Count of services with `ok == true` (healthy enough to use).
        let healthyCount: Int

        struct Service: Encodable, Sendable {
            /// Stable canonical name. Agents key on this for
            /// "compare last call's snapshot to this one."
            let name: String
            /// Hostname the probe contacted. Helpful for users
            /// reading the response who want to know which mirror
            /// answered.
            let host: String
            /// `"ok"` — service answered usefully (2xx/3xx, or 401/403
            ///   on an auth probe — host is up, credentials omitted).
            /// `"degraded"` — host returned 5xx, or a 404 on a path that
            ///   should exist (not healthy; Windows 1.3.3 honesty).
            /// `"down"` — DNS / connect / TLS / timeout.
            /// `"skipped"` — plaintext-http blocked by ATS.
            let status: String
            /// Whether an agent should treat the service as usable.
            let ok: Bool
            /// Round-trip in milliseconds. `nil` only for the
            /// `"down"` / `"skipped"` cases that didn't complete.
            let latencyMs: Int?
            /// Optional one-liner: HTTP status code, error message.
            let message: String?
        }
    }

    var toolTimeoutSeconds: TimeInterval { 30 }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_service_health",
        description: "Probe the upstream services Verbinal depends on (CADC auth/TAP, VOSpace, Skaha, VizieR mirrors) and return a per-service health snapshot. Use BEFORE long pipelines to decide whether to proceed or pause: when `vizier-cds-unistra` is down your cone searches will fail; when `skaha` is down no Skaha session will launch. Each entry has `status` (`ok`/`degraded`/`down`/`skipped`), `ok` (bool — usable?), and the summary's `healthyCount`. Auth is probed at `/whoami` (not the AC base URL, which always 404s). A 404/5xx is NOT healthy. `skipped` = plaintext-http blocked by App Transport Security.",
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

    /// Build the deployment-dependent probe set for the configured
    /// endpoints: archive (TAP + resolver), VOSpace, Skaha, and the IVOA
    /// registry follow the endpoint settings; the VizieR mirrors are
    /// global infrastructure shared by every deployment. Probe URL is the
    /// canonical IVOA `/availability` off each service root.
    static func deploymentEndpoints(for endpoints: APIEndpoints) -> [Endpoint] {
        func host(_ urlString: String) -> String {
            URL(string: urlString)?.host ?? "?"
        }
        // VOSpace service root = the storage URL minus its node-path suffix.
        let vospaceRoot = endpoints.storageBaseURL
            .replacingOccurrences(of: "/nodes/home", with: "")
        return [
            Endpoint(
                name: "cadc-auth",
                host: host(endpoints.loginBaseURL),
                // /whoami — the AC base URL itself always 404s and used
                // to be mis-reported as healthy (Windows 1.3.3 F3).
                url: endpoints.whoAmIURL
            ),
            Endpoint(
                name: "cadc-registry",
                host: host(endpoints.registryBaseURL),
                url: endpoints.registryAvailabilityURL
            ),
            Endpoint(
                name: "cadc-tap",
                host: host(endpoints.archiveBaseURL),
                url: "\(endpoints.archiveBaseURL)/argus/availability"
            ),
            Endpoint(
                name: "cadc-resolver",
                host: host(endpoints.archiveBaseURL),
                url: "\(endpoints.archiveBaseURL)/cadc-target-resolver/availability"
            ),
            Endpoint(
                name: "vospace",
                host: host(vospaceRoot),
                url: "\(vospaceRoot)/availability"
            ),
            Endpoint(
                name: "skaha",
                host: host(endpoints.skahaBaseURL),
                url: "\(endpoints.skahaBaseURL)/availability"
            ),
        ] + vizierMirrors
    }

    /// VizieR mirrors — deployment-independent; probed regardless of the
    /// configured endpoints. The mirrors cone searches go to, and no others.
    static let vizierMirrors: [Endpoint] = TAPClient.queryableVizierEndpoints.map {
        Endpoint(name: "vizier-\($0.name)", host: $0.host, url: $0.availabilityURL)
    }

    /// Canonical (classic-CANFAR) service set — the `deploymentEndpoints`
    /// derivation applied to the historical defaults. Tests pin this shape;
    /// the live wireup passes the effective endpoints instead.
    static let canonicalEndpoints: [Endpoint] = deploymentEndpoints(for: APIEndpoints())

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
        let healthy = services.filter(\.ok).count
        return Output(services: services, probeStartedISO: startISO, healthyCount: healthy)
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
                status: "down", ok: false, latencyMs: nil,
                message: "invalid url: \(endpoint.url)"
            )
        }
        // App Transport Security blocks plaintext http on Apple platforms,
        // so a probe of an http-only mirror (e.g. the China-VO VizieR
        // mirror) can NEVER succeed regardless of the mirror's real
        // health — attempting it just yields a misleading "down". Report
        // it as "skipped" up front instead (2026-07-21 Mac QA, F13).
        #if os(macOS) || os(iOS)
        if url.scheme?.lowercased() == "http" {
            return Output.Service(
                name: endpoint.name, host: endpoint.host,
                status: "skipped", ok: false, latencyMs: nil,
                message: "plaintext HTTP blocked by App Transport Security on macOS/iOS — not probed"
            )
        }
        #endif
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
                    status: "down", ok: false, latencyMs: latencyMs,
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
                status: "down", ok: false, latencyMs: nil,
                message: error.localizedDescription
            )
        }
    }

    /// Status code → status / ok. Pulled out as a pure function so tests
    /// can pin the classification rules without spinning a URLSession.
    static func classify(
        name: String, host: String, statusCode: Int, latencyMs: Int?
    ) -> Output.Service {
        switch statusCode {
        case 500...599:
            return Output.Service(
                name: name, host: host,
                status: "degraded", ok: false, latencyMs: latencyMs,
                message: "HTTP \(statusCode)"
            )
        case 401, 403:
            // Auth probe without credentials — host is up.
            return Output.Service(
                name: name, host: host,
                status: "ok", ok: true, latencyMs: latencyMs,
                message: "HTTP \(statusCode) — host reachable (credentials omitted on probe)"
            )
        case 404:
            // 404 is NOT healthy (Windows 1.3.3): probing an AC base URL
            // always 404'd and was mis-reported as ok. Same for a missing
            // /availability — treat as degraded, not usable.
            return Output.Service(
                name: name, host: host,
                status: "degraded", ok: false, latencyMs: latencyMs,
                message: "HTTP 404 — probe path missing or wrong"
            )
        case 400...499:
            return Output.Service(
                name: name, host: host,
                status: "degraded", ok: false, latencyMs: latencyMs,
                message: "HTTP \(statusCode)"
            )
        default:
            return Output.Service(
                name: name, host: host,
                status: "ok", ok: true, latencyMs: latencyMs,
                message: nil
            )
        }
    }
}
