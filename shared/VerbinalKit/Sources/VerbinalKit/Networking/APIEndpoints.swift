// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public struct APIEndpoints: Sendable, Equatable {
    public var loginBaseURL: String
    public var skahaBaseURL: String
    public var acBaseURL: String
    public var storageBaseURL: String
    /// IVOA registry service base. Serves `resource-caps` (the map from
    /// `ivo://` resource IDs to VOSI capabilities documents) plus the
    /// registry's own availability endpoint. CADC's west registry, off the
    /// archive's host, so the map is there when that host is down (plan 21).
    public var registryBaseURL: String
    /// CADC archive base — TAP, CAOM2 metadata, DataLink, packaging.
    /// Single root means changing CADC's host name happens in one place.
    public var archiveBaseURL: String
    /// External web URLs (browser-targeted, not REST).
    public var externalBaseURL: String
    /// Default cap on TAP MAXREC — large enough to cover normal browsing
    /// without breaking the server's response budget.
    public var tapMaxRecords: Int
    /// Each URL as its service publishes it in the registry (plan 53 B2):
    /// a derived URL uses its capability's when there is one, and the base
    /// plus its usual path otherwise.
    public var capabilityURLs: [ServiceCapability: String]
    /// Each service's root, by resource ID, from its VOSI availability in
    /// the registry: where its health is asked (plan 53).
    public var serviceRoots: [String: String]

    /// The defaults are where the registry put each service on 2026-10-28
    /// (plan 53 B4): what is used until the registry has answered once.
    public init(
        loginBaseURL: String = "https://cadc-west-01.canfar.net/ac",
        skahaBaseURL: String = "https://ws-uv.canfar.net/skaha",
        acBaseURL: String = "https://cadc-west-01.canfar.net/ac",
        storageBaseURL: String = "https://ws-uv.canfar.net/arc/nodes/home",
        registryBaseURL: String = "https://cadc-west-01.canfar.net/reg",
        archiveBaseURL: String = "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        externalBaseURL: String = "https://www.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        tapMaxRecords: Int = 30000,
        capabilityURLs: [ServiceCapability: String] = [:],
        serviceRoots: [String: String] = [:]
    ) {
        self.loginBaseURL = loginBaseURL
        self.skahaBaseURL = skahaBaseURL
        self.acBaseURL = acBaseURL
        self.storageBaseURL = storageBaseURL
        self.registryBaseURL = registryBaseURL
        self.archiveBaseURL = archiveBaseURL
        self.externalBaseURL = externalBaseURL
        self.tapMaxRecords = tapMaxRecords
        self.capabilityURLs = capabilityURLs
        self.serviceRoots = serviceRoots
    }

    /// Where `resourceID`'s service says whether it is available: its root
    /// as the registry published it, or `root`, plus `/availability`.
    public func availabilityURL(of resourceID: String, else root: @autoclosure () -> String) -> String {
        "\(serviceRoots[resourceID] ?? root())/availability"
    }

    /// `capability`'s URL as the registry published it, or `fallback`.
    private func url(_ capability: ServiceCapability, else fallback: @autoclosure () -> String) -> String {
        capabilityURLs[capability] ?? fallback()
    }

    // MARK: - IVOA Registry

    /// Plain-text map of `ivo://` resource IDs → capabilities URLs.
    public var resourceCapsURL: String { "\(registryBaseURL)/resource-caps" }
    /// VOSI availability of the registry service.
    public var registryAvailabilityURL: String { "\(registryBaseURL)/availability" }

    public var loginURL: String { url(.login, else: "\(loginBaseURL)/login") }
    public var whoAmIURL: String { url(.whoami, else: "\(loginBaseURL)/whoami") }
    public func userURL(_ username: String) -> String {
        "\(url(.users, else: "\(loginBaseURL)/users"))/\(username)?idType=HTTP&detail=display"
    }

    public var sessionsURL: String { url(.sessions, else: "\(skahaBaseURL)/v1/session") }
    public func sessionURL(_ id: String) -> String { "\(sessionsURL)/\(id)" }
    public func sessionRenewURL(_ id: String) -> String { "\(sessionsURL)/\(id)?action=renew" }
    /// One desktop app, under its desktop's session id.
    public func desktopAppURL(_ session: String, _ app: String) -> String { "\(sessionsURL)/\(session)/app/\(app)" }
    public func sessionEventsURL(_ id: String) -> String { "\(sessionsURL)/\(id)?view=events" }
    public func sessionLogsURL(_ id: String) -> String { "\(sessionsURL)/\(id)?view=logs" }
    public var statsURL: String { "\(sessionsURL)?view=stats" }

    public var imagesURL: String { url(.images, else: "\(skahaBaseURL)/v1/image") }
    public var contextURL: String { url(.context, else: "\(skahaBaseURL)/v1/context") }
    public var repositoryURL: String { url(.repository, else: "\(skahaBaseURL)/v1/repository") }

    public func storageURL(_ username: String) -> String { "\(storageBaseURL)/\(username)?limit=0" }

    // MARK: - CADC Archive (TAP / CAOM2 / DataLink)

    /// Synchronous TAP query endpoint (Argus). Accepts ADQL via POST.
    public var tapSyncURL: String { "\(url(.tap, else: "\(archiveBaseURL)/argus"))/sync" }
    /// Per-observation CAOM2 metadata document. ID query: `caom:{collection}/{obsID}`.
    public var caom2MetaURL: String { url(.meta, else: "\(archiveBaseURL)/caom2ops/meta") }
    /// IVOA DataLink-1.1 (file/cutout/preview links). ID query: publisher URI.
    public var datalinkURL: String { url(.datalink, else: "\(archiveBaseURL)/caom2ops/datalink") }
    /// Packaging endpoint for direct file downloads.
    public var caom2PkgURL: String { url(.pkg, else: "\(archiveBaseURL)/caom2ops/pkg") }
    /// Target name resolver (Sesame-style → coordinates).
    public var targetResolverURL: String { url(.resolver, else: "\(archiveBaseURL)/cadc-target-resolver/find") }

    /// Browser-facing CAOM2 UI observation viewer.
    public var caom2UIViewURL: String { "\(externalBaseURL)/caom2ui/view" }
    /// Legacy in-browser download manager.
    public var downloadManagerURL: String { "\(externalBaseURL)/downloadManager/download" }

    /// Direct download URL for a single CAOM-2 artefact URI of the
    /// form `<scheme>:<collection>/<path>` (e.g.
    /// `cadc:JCMT/scuba2_foo.fits.gz`). Returns `nil` for inputs
    /// that don't carry a `<scheme>:` prefix.
    ///
    /// The host is the same archive base every other CADC service
    /// lives on; the path is `/data/pub/` + everything after the
    /// scheme's colon. Lives here so any caller can convert an
    /// artefact URI without re-typing the host pattern — the URL
    /// shape was previously a manual derivation step the 2026-05-13
    /// QA pass had to perform by hand.
    public func dataPubURL(forArtifactURI uri: String) -> URL? {
        guard let colon = uri.firstIndex(of: ":") else { return nil }
        let rest = uri[uri.index(after: colon)...]
        guard !rest.isEmpty else { return nil }
        // Percent-encode each path segment so filenames containing
        // `#`, `?`, `%`, spaces, etc. round-trip cleanly through
        // URLSession. Slashes between collection and filename are
        // preserved.
        let encodedRest = rest
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
                return String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
        return URL(string: "\(url(.files, else: "\(archiveBaseURL)/data/pub"))/\(encodedRest)")
    }
}
