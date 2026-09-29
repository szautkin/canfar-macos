// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What launches batch jobs on the platform.
protocol HeadlessLaunching: Sendable {
    func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String]
}

extension HeadlessService: HeadlessLaunching {}

/// Launching a batch job, on the activity bar, whoever asks: the Batch
/// Jobs form and an assistant's `launch_headless_job`. An assistant's
/// launch went straight to the platform and never reached the bar (plan
/// 19 T1, QA A1), as its session deletes once did (`SessionActions`).
@MainActor
final class HeadlessLaunches {
    private let service: any HeadlessLaunching
    private let tasks: TaskRegistry

    init(service: any HeadlessLaunching, tasks: TaskRegistry = .shared) {
        self.service = service
        self.tasks = tasks
    }

    /// The launched jobs' ids. A partial replica failure throws, as the
    /// service does, and the bar says how many are running.
    func launch(_ params: HeadlessLaunchParams) async throws -> [String] {
        let task = tasks.begin(.launch, String(localized: "Launch batch job \(params.name)"))
        do {
            let ids = try await service.launchHeadlessJob(params)
            task.succeed(ids.count == 1 ? String(localized: "Job \(ids[0])") : String(localized: "\(ids.count) jobs"))
            return ids
        } catch {
            task.fail(error.localizedDescription)
            throw error
        }
    }
}
