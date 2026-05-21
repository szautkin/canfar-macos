// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Convenience refinement of `AITool` for *read* tools that take typed
/// JSON arguments and return a typed JSON body.
///
/// Concrete read tools conform to this and implement `handle(_:context:)`;
/// the default `invoke` deals with decoding/encoding and ferries throws
/// into `ToolFailureReason`. Cuts the boilerplate per-tool from ~30 lines
/// to ~10 — and centralises the JSON-error envelope so audit tags stay
/// consistent across the surface.
public protocol JSONReadTool: AITool {
    associatedtype Args: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    /// Implement the tool's actual work. Throw a `ToolFailureReason` to
    /// surface a typed failure; any other error wraps as `.backendError`.
    func handle(_ args: Args, context: AIToolContext) async throws -> Output

    /// Wall-clock deadline applied around every `handle(_:context:)`
    /// invocation. Default 60s.
    ///
    /// Override for outliers: fast-listing tools should drop to 30s
    /// (the QA report named `list_headless_jobs` as the recurring
    /// 5-minute hang; bounding it tightly is the whole point); heavy
    /// TAP queries that legitimately take 30–60s should extend to
    /// 90–120s. The watchdog throws `ToolFailureReason.backendError`
    /// with a recognisable "<label> exceeded Ns deadline" body — the
    /// agent gets a typed error instead of an indefinite stall.
    var toolTimeoutSeconds: TimeInterval { get }
}

extension JSONReadTool {
    public static var verbClass: VerbClass { .read }
    public static var agentSafe: Bool { true }

    /// 60 seconds is the comfortable default for CADC services
    /// (TAP, DataLink, target-resolver, VOSpace listing, Skaha
    /// session/headless listing). Per-tool overrides tighten this
    /// for fast-list endpoints and loosen for known-slow queries.
    public var toolTimeoutSeconds: TimeInterval { 60 }

    public func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        if Args.self == EmptyArgs.self, arguments.isNullOrEmpty {
            // Special case: tools with no args; agents may pass null,
            // omit `arguments`, or send `{}`. Synthesise an EmptyArgs.
            args = (EmptyArgs() as! Args)
        } else {
            do {
                args = try JSONDecoder().decode(Args.self, from: arguments)
            } catch {
                return .failed(.invalidArgument("\(error)"))
            }
        }
        do {
            // The deadline-exceeded message names the offending tool
            // so the agent's error log identifies which call stalled
            // — not just that *something* did.
            let toolName = definition.name
            let output = try await withToolTimeout(
                seconds: toolTimeoutSeconds,
                label: toolName
            ) {
                try await handle(args, context: context)
            }
            let bytes = try JSONEncoder().encode(output)
            return .data(bytes)
        } catch let failure as ToolFailureReason {
            return .failed(failure)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

/// Marker `Args` type for tools that take no parameters.
public struct EmptyArgs: Codable, Sendable {
    public init() {}
}

extension ToolFailureReason: Error {}

private extension Data {
    /// True when the bytes are missing, empty, or the literal `null`.
    var isNullOrEmpty: Bool {
        if isEmpty { return true }
        guard let s = String(data: self, encoding: .utf8) else { return false }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null"
    }
}
