// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The platform accepted a launch and named no session: not a launch.
struct LaunchedWithoutID: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "The server accepted the launch but returned no session ID.")
    }
}

/// Launching a session, on the activity bar, whoever asks: the launch form,
/// a relaunch from Recent Launches, and an assistant's `launch_session`. An
/// assistant's went straight to the platform and never reached the bar, as
/// its batch jobs once did (`HeadlessLaunches`; plan 30 W1).
///
/// A launch tried again after one that failed asks first whether the
/// platform made it all the same: a launch that timed out may have been
/// made, and a second would be a second session (plan 30 W4).
@MainActor
final class SessionLaunches {
    /// The session, and whether it was already there.
    struct Launched: Equatable, Sendable {
        let id: String
        let alreadyMade: Bool
    }

    private let service: any SessionLaunching
    private let listing: (any SessionEnding)?
    private let tasks: TaskRegistry

    init(service: any SessionLaunching, listing: (any SessionEnding)? = nil, tasks: TaskRegistry = .shared) {
        self.service = service
        self.listing = listing
        self.tasks = tasks
    }

    /// Launches it, or — when `checkFirst` — finds the session of its name the
    /// platform already lists and launches nothing.
    func launch(_ params: SessionLaunchParams, checkFirst: Bool = false) async throws -> Launched {
        let task = tasks.begin(.launch, String(localized: "Launch \(params.type) \(params.name)"))
        do {
            if checkFirst, let made = try await listing?.listing().first(where: {
                $0.name == params.name && !$0.isDesktopApp && !$0.isEnding
            }) {
                task.succeed(String(localized: "Already made: \(made.id)"))
                return Launched(id: made.id, alreadyMade: true)
            }
            guard let id = try await task.within({ try await service.launchSession(params) }) else {
                throw LaunchedWithoutID()
            }
            task.succeed(String(localized: "Session \(id)"))
            return Launched(id: id, alreadyMade: false)
        } catch {
            task.fail(error.localizedDescription)
            throw error
        }
    }
}

/// Whether the apply under way is a change being tried again after it
/// failed — so a launch first asks whether it was made all the same, and a
/// delete of what is already gone is done (plan 30 W4).
enum ApplyAttempt {
    @TaskLocal static var isRetry = false
}
