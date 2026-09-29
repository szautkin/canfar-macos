// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Why a probe job failed, in one line: the last line of its log that
/// reads as an error, else the last Warning among its events, else nil —
/// the job's status then speaks for it.
///
/// A log's last line was often a status message printed after the error,
/// and a job that failed before it logged anything (an image that would
/// not pull) said nothing at all (QA L17).
enum ProbeFailureReason {
    /// The longest reason kept, from the line's end, where the error is.
    static let maxLength = 300

    /// Words an error line carries, however it is cased.
    private static let errorWords = ["error", "exception", "traceback", "killed", "oom", "out of memory", "fatal",
                                     "panic", "segmentation fault", "permission denied", "no such file", "not found",
                                     "failed"]

    static func from(log: String?, events: String?) -> String? {
        let reason = log.flatMap(errorLine) ?? events.flatMap(lastWarning)
        return reason.map { $0.count > maxLength ? String($0.suffix(maxLength)) : $0 }
    }

    /// The log's last line that reads as an error.
    static func errorLine(_ log: String) -> String? {
        lines(log).last { line in
            let lowered = line.lowercased()
            return errorWords.contains { lowered.contains($0) }
        }
    }

    /// The last event of type Warning, without its type, its columns
    /// closed up — `Failed  Error: ErrImagePull …`.
    static func lastWarning(_ events: String) -> String? {
        let words = lines(events).map { $0.split(whereSeparator: \.isWhitespace) }
        guard let warning = words.last(where: { $0.first?.lowercased() == "warning" }), warning.count > 1 else { return nil }
        return warning.dropFirst().joined(separator: " ")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
