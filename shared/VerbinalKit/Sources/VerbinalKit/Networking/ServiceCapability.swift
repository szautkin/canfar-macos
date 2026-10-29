// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One URL Verbinal calls, as its service publishes it in the registry
/// (plan 53 B1): the service's resource ID, and the standard ID of the
/// capability whose access URL it is. The registry says where each is, so
/// a service that moves is followed without a release.
public enum ServiceCapability: String, CaseIterable, Codable, Sendable {
    case login, whoami, users
    case sessions, images, context, repository
    case nodes
    case tap, datalink, meta, pkg, resolver, files

    public var resourceID: String {
        switch self {
        case .login, .whoami, .users: "ivo://cadc.nrc.ca/gms"
        case .sessions, .images, .context, .repository: "ivo://cadc.nrc.ca/skaha"
        case .nodes: "ivo://cadc.nrc.ca/arc"
        case .tap: "ivo://cadc.nrc.ca/argus"
        case .datalink, .meta, .pkg: "ivo://cadc.nrc.ca/caom2ops"
        case .resolver: "ivo://cadc.nrc.ca/resolver"
        case .files: "ivo://cadc.nrc.ca/data"
        }
    }

    public var standardID: String {
        switch self {
        case .login: "ivo://ivoa.net/std/UMS#login-0.1"
        case .whoami: "ivo://ivoa.net/std/UMS#whoami-0.1"
        case .users: "ivo://ivoa.net/std/UMS#users-0.1"
        case .sessions: "http://www.opencadc.org/std/platform#session-1"
        case .images: "http://www.opencadc.org/std/platform#image-1"
        case .context: "http://www.opencadc.org/std/platform#context-1"
        case .repository: "http://www.opencadc.org/std/platform#repository-1"
        case .nodes: "ivo://ivoa.net/std/VOSpace/v2.0#nodes"
        case .tap: "ivo://ivoa.net/std/TAP"
        case .datalink: "ivo://ivoa.net/std/DataLink#links-1.1"
        case .meta: "vos://cadc.nrc.ca~vospace/CADC/std/CAOM2#obs-1.0"
        case .pkg: "vos://cadc.nrc.ca~vospace/CADC/std/Pkg-1.0"
        case .resolver: "vos://cadc.nrc.ca~vospace/CADC/std/NameResolver#names-1.0"
        case .files: "vos://cadc.nrc.ca~vospace/CADC/std/archive#file-1.0"
        }
    }
}
