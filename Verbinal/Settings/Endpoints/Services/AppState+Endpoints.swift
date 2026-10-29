// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The endpoints in use follow the registry and the person (plan 53 C).
extension AppState {
    /// Wired once, at launch: a registry answer or an override applies at
    /// once, and a service in trouble asks the registry again.
    func connectEndpoints() {
        endpointRegistry.onChange = { [weak self] in self?.applyEndpoints() }
        endpointSettings.onChange = { [weak self] in self?.applyEndpoints() }
        let registry = endpointRegistry
        Task { [network] in
            await network.setServiceTroubleHandler { _ in await registry.serviceInTrouble() }
        }
    }

    /// The endpoints the services read become what the registry and the
    /// person say now, and the token may go to their hosts; each service
    /// reached somewhere else is recorded (plan 53 C4).
    func applyEndpoints() {
        let now = endpointRegistry.effectiveEndpoints()
        let before = liveEndpoints.current
        guard now != before else { return }
        liveEndpoints.update(now)
        Task { [network] in await network.setTrustedAuthHostSuffixes(NetworkClient.trustedHostSuffixes(from: now)) }
        for moved in EndpointMoves.between(before, now) { DecisionLog.shared.record(.serviceMoved, moved) }
    }
}

/// What moved between two sets of endpoints, as the decision log says it.
enum EndpointMoves {
    private static var watched: [(label: String, url: (APIEndpoints) -> String)] {
        [
            ("Sign-in", \.loginURL), ("The account service", \.acBaseURL), ("Sessions", \.sessionsURL),
            ("Images", \.imagesURL), ("Storage", \.storageBaseURL), ("The archive search", \.tapSyncURL),
            ("DataLink", \.datalinkURL), ("Observation metadata", \.caom2MetaURL), ("Packages", \.caom2PkgURL),
            ("The name resolver", \.targetResolverURL),
        ]
    }

    static func between(_ before: APIEndpoints, _ after: APIEndpoints) -> [String] {
        watched.compactMap { label, url in
            let old = url(before), new = url(after)
            return old == new ? nil : "\(label) is now reached at \(new), not \(old)."
        }
    }
}
