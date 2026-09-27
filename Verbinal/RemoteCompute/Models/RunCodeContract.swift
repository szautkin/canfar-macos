// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The file-drop contract literals. These MUST stay byte-for-byte in sync
/// with the watcher image (`dev_info/verbinal-compute-image-spec.md`); a
/// mismatch fails silently (the agent polls an output file the watcher
/// wrote elsewhere).
enum RunCodeContract {
    static let sessionName = "verbinal-compute"
    static let sessionType = "contributed"
    /// The coordination folder in the person's home — "Open folder in Storage".
    static let execDir  = ".verbinal/exec"
    static let inboxDir = ".verbinal/exec/inbox"
    static let outDir   = ".verbinal/exec/out"
    /// Result file hard cap — matches `read_vospace_file`'s 1 MB ceiling.
    static let maxResultBytes = 1024 * 1024
    static let supportedLanguages = ["python", "bash"]
    static let defaultTimeoutSeconds = 60
    static let maxTimeoutSeconds = 900

    /// Resource bounds for the compute instance. The default size is the
    /// Settings-resolved value (`AIComputeImage.resolvedResources()`);
    /// these constants are the floor (1) the lazy launch falls back to
    /// and the ceiling agent-requested sizes are clamped to. Resources
    /// are an INSTANCE property — set once at `start_compute` (or the
    /// `run_code` self-launch) and fixed for that instance's lifetime.
    static let defaultCores = 1
    static let defaultRam = 1
    static let maxCores = 64
    static let maxRam = 256

    static func clampCores(_ value: Int) -> Int { min(max(value, 1), maxCores) }
    static func clampRam(_ value: Int) -> Int { min(max(value, 1), maxRam) }
    static func clampTimeout(_ seconds: Int) -> Int { min(max(seconds, 1), maxTimeoutSeconds) }

    /// Code leaves with Unix line endings, whoever wrote it — a script with
    /// `\r\n` fails in bash on the session.
    static func normalizeNewlines(_ code: String) -> String {
        code.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Sanitize a request id for filesystem use. The 9-character set
    /// `/ : \ ? * < > | "` MUST match the watcher image and Verbinal's
    /// `ImageManifest.sanitize` byte-for-byte, or id-derived filenames
    /// won't agree across the two sides.
    static func sanitize(_ id: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "?", "*", "<", ">", "|", "\""]
        return String(id.map { bad.contains($0) ? "_" : $0 })
    }
    static func inboxPath(id: String) -> String { "\(inboxDir)/\(sanitize(id)).json" }
    static func outPath(id: String) -> String { "\(outDir)/\(sanitize(id)).json" }

    /// Client → watcher. Single JSON object PUT to the inbox.
    struct Request: Codable, Sendable {
        let id: String
        let language: String
        let code: String
        let timeout_seconds: Int
    }

    /// Watcher → client. Decoded leniently (every field optional) so a
    /// partially-written or older-schema result degrades to "not ready"
    /// rather than throwing.
    struct ResultFile: Codable, Sendable, Equatable {
        let id: String?
        let status: String?
        let exit_code: Int?
        let stdout: String?
        let stdout_encoding: String?
        let stderr: String?
        let stderr_encoding: String?
        let duration_ms: Int?
        let truncated: Bool?
        let started_at: String?
        let finished_at: String?

        /// The output as text: base64 decoded where the watcher encoded it.
        var decodedStdout: String? { Self.decode(stdout, stdout_encoding) }
        var decodedStderr: String? { Self.decode(stderr, stderr_encoding) }

        private static func decode(_ value: String?, _ encoding: String?) -> String? {
            guard let value, encoding?.lowercased() == "base64" else { return value }
            return Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? value
        }
    }

    /// What reading a run's result file found.
    enum Fetched: Equatable, Sendable {
        /// Not written yet — the session is starting or still running it.
        case absent
        /// Present but not whole: a write still propagating on /arc.
        case incomplete
        case done(ResultFile)

        init(_ data: Data?) {
            guard let data else { self = .absent; return }
            self = (try? JSONDecoder().decode(ResultFile.self, from: data)).map(Fetched.done) ?? .incomplete
        }
    }

    /// Minimal view of a session for the reuse decision — keeps the pure
    /// choice logic testable without the Session model.
    struct SessionInfo: Sendable, Equatable {
        let id: String
        let type: String
        let name: String
        let status: String   // raw Skaha status: running / pending / terminating / …
    }

    /// The id of a warm session to reuse, or nil to launch a new one: a
    /// `contributed` session WE launched (matched by its pinned name) that is
    /// running OR still provisioning (`pending`) — never terminating/failed.
    /// Matching by name (not the image string) is robust to `launchSession`'s
    /// registry-prefix normalization, and counting `pending` stops rapid
    /// cold-start calls from spawning duplicate sessions.
    static func reusableSessionID(in sessions: [SessionInfo], name: String) -> String? {
        sessions.first { $0.type.lowercased() == sessionType && $0.name == name && isLive($0.status) }?.id
    }

    /// Running or still starting — a session to reuse, not to launch beside.
    static func isLive(_ status: String) -> Bool {
        ["running", "pending"].contains(status.lowercased())
    }
}

