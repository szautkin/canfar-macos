// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

final class HeadlessService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Fetches only headless sessions, filtering client-side.
    func getHeadlessJobs() async throws -> [HeadlessJob] {
        let responses = try await network.getJSON(
            endpoints.sessionsURL,
            type: [SkahaHeadlessResponse].self
        )
        return responses
            .filter { $0.type.lowercased() == "headless" }
            .map { HeadlessJob(from: $0) }
    }

    /// Fetches container logs for a headless job.
    func getLogs(id: String) async throws -> String {
        try await network.getText(endpoints.sessionLogsURL(id))
    }

    /// Fetches Kubernetes events for a headless job.
    func getEvents(id: String) async throws -> String {
        try await network.getText(endpoints.sessionEventsURL(id))
    }

    /// Deletes a headless job by ID.
    func deleteJob(id: String) async throws {
        _ = try await network.delete(endpoints.sessionURL(id))
    }

    /// Launch one or more replicas of a headless Skaha job. Returns
    /// the session ids in launch order.
    ///
    /// Wire shape mirrors the canonical Python `canfar` client:
    /// each replica is its own POST to `/skaha/v1/session` with form
    /// body containing `type=headless`, `name`, `image`, optional
    /// `cmd` / `args`, optional `cores` / `ram` / `gpus`, and a
    /// repeated `env=KEY=VAL` field per environment variable plus
    /// auto-injected `REPLICA_ID` / `REPLICA_COUNT` for each replica
    /// in the loop. The `replicas` form field itself is included for
    /// parity with the Python client even though Skaha ignores it
    /// server-side.
    ///
    /// Failure semantics: best-effort partial success. If replica N
    /// fails, this method throws
    /// `HeadlessLaunchError.partialReplicaFailure` with the ids of
    /// replicas 0..<N that DID launch — the caller decides whether
    /// to roll back via `deleteJob`. Replicas N+1.. are not attempted.
    /// A failure on the very first replica throws the underlying
    /// network error directly (no partial state).
    func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String] {
        let count = max(1, params.replicas)
        var jobIDs: [String] = []

        for replica in 0..<count {
            let replicaName = count == 1 ? params.name : "\(params.name)-\(replica + 1)"

            var pairs: [(String, String)] = [
                ("type", "headless"),
                ("name", replicaName),
                ("image", params.image)
            ]
            if let cmd = params.cmd, !cmd.isEmpty {
                pairs.append(("cmd", cmd))
            }
            if let args = params.args, !args.isEmpty {
                pairs.append(("args", args))
            }
            if let cores = params.cores, cores > 0 {
                pairs.append(("cores", String(cores)))
            }
            if let ram = params.ram, ram > 0 {
                pairs.append(("ram", String(ram)))
            }
            if let gpus = params.gpus, gpus > 0 {
                pairs.append(("gpus", String(gpus)))
            }
            for (key, value) in params.env {
                pairs.append(("env", "\(key)=\(value)"))
            }
            // Auto-inject Python-client parity env vars.
            pairs.append(("env", "REPLICA_ID=\(replica + 1)"))
            pairs.append(("env", "REPLICA_COUNT=\(count)"))
            if count > 1 {
                pairs.append(("replicas", String(count)))
            }

            // Build `x-skaha-registry-auth` header when the caller
            // supplied registry credentials (image discovery's
            // settings-driven path, or any future call site that
            // needs Harbor auth). Skaha rejects pulls from private
            // namespaces with HTTP 400 when the header is absent.
            // Built once per replica because the header value is a
            // constant for the whole launch fan-out.
            var headers: [String: String]?
            if let auth = params.registryAuthHeader, !auth.isEmpty {
                headers = ["x-skaha-registry-auth": auth]
            }
            do {
                let (data, _) = try await network.post(
                    endpoints.sessionsURL,
                    formPairs: pairs,
                    headers: headers,
                    // CADC's session-create endpoint regularly takes
                    // 60–90s when the cluster's K8s API is busy.
                    // 180s is a generous patience floor; the
                    // ImageDiscoveryCoordinator's K8s-race retry
                    // wraps a separate, shorter budget on top.
                    timeout: 180
                )
                let id = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty else {
                    if jobIDs.isEmpty {
                        throw HeadlessLaunchError.emptyResponse
                    }
                    throw HeadlessLaunchError.partialReplicaFailure(
                        launchedIDs: jobIDs,
                        failedAtIndex: replica,
                        underlyingMessage: "Skaha returned empty response"
                    )
                }
                jobIDs.append(id)
            } catch let partial as HeadlessLaunchError {
                throw partial
            } catch {
                if jobIDs.isEmpty {
                    throw error
                }
                throw HeadlessLaunchError.partialReplicaFailure(
                    launchedIDs: jobIDs,
                    failedAtIndex: replica,
                    underlyingMessage: error.localizedDescription
                )
            }
        }

        return jobIDs
    }
}
