// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Fetch DataLink-discovered URLs for an observation plus the full
/// CAOM-2 artefact inventory. `bestDirectFile` is the agent's
/// recommended starting point for a download.
///
/// Output has two complementary views:
///  * `files[]` — DataLink `#this` rows: directly-downloadable URLs
///    for science products. May be empty if the DataLink service
///    doesn't index this observation (proprietary collections,
///    embargoed data, partial mirror sync).
///  * `caom2Artifacts[]` — Every artefact CAOM-2 lists for the
///    observation: science, weight, preview, auxiliary, provenance.
///    Always populated when CAOM-2 fetch succeeds, regardless of
///    `files`. Agents use this to discover sibling products that
///    DataLink suppresses (weight maps, aux files, …).
///
/// `packageDownloadURL` points at `/caom2ops/pkg?ID=publisherID`,
/// which always works for downloadable observations even when
/// DataLink is silent.
struct GetDataLinksTool: JSONReadTool {
    // 30s deadline matches the inline documentation in the tool's
    // description ("wrapped in a 30-second watchdog"). DataLink +
    // CAOM-2 parallel fetch should complete well inside this; past
    // that the agent gets a recognisable deadline error instead of
    // the multi-minute hang the 2026-05-13 QA pass observed.
    var toolTimeoutSeconds: TimeInterval { 30 }

    struct Args: Decodable, Sendable {
        let publisher_id: String
    }

    struct Output: Encodable, Sendable {
        let thumbnails: [String]
        let previews: [String]
        let files: [FileOut]
        let bestDirectFileURL: String?
        /// Artefact URIs from the CAOM-2 record. Populated *only* when
        /// DataLink returned no direct files — DataLink's URL-bearing
        /// rows take precedence whenever they exist.
        let caom2Artifacts: [ArtifactOut]
        /// Package-download URL (`/caom2ops/pkg?ID=…`) — works even
        /// when DataLink is silent. Returns a tar containing every
        /// downloadable artefact for the observation.
        let packageDownloadURL: String?

        struct FileOut: Encodable, Sendable {
            let url: String
            let contentType: String
            let filename: String
            let isUncompressedFITS: Bool
        }

        struct ArtifactOut: Encodable, Sendable {
            /// Canonical artefact URI (`cadc:CFHT/729989p.fits.fz`).
            let uri: String
            /// `science`, `preview`, `auxiliary`, …
            let productType: String?
            let contentType: String?
            let contentLength: Int64?
            let filename: String
            /// Directly-downloadable HTTPS URL derived from the
            /// artefact URI (e.g.
            /// `https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/JCMT/scuba2_…fits.gz`).
            /// Saves the agent a manual URL-construction step
            /// that was previously a documented friction point —
            /// the URL pattern depends on the artefact's URI
            /// scheme, which only the host knows authoritatively.
            let downloadURL: String?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_data_links",
        description: "Fetch thumbnail / preview / direct-download URLs for a CADC observation by publisher_id, plus the full CAOM-2 artefact inventory. **For a single file you can fetch directly from inside a Skaha container**, use `caom2Artifacts[i].downloadURL` — it's a ready-to-curl HTTPS URL on `ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/<collection>/<file>`, no construction needed and no DataLink round-trip required for public collections. `files[]` is DataLink #this when available (sometimes empty for public-archive-only observations); `caom2Artifacts[]` is the full inventory (science + weight + preview + aux + provenance), always populated when CAOM-2 is reachable. Use `files[]` for whatever DataLink advertises, `caom2Artifacts[]` for direct-by-name fetches and to discover sibling products DataLink suppresses. `packageDownloadURL` always works as a tarball fallback. Wrapped in a 30-second watchdog to bound the rare DataLink-service hang the 2026-05 QA review documented.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure shape so the tool doesn't depend on TAPClient / CAOM2Service
    /// directly, keeping unit tests simple. The wiring layer composes
    /// DataLink + CAOM-2 artefact fallback + package-URL builder; the tool
    /// itself just shapes the result for JSON encoding.
    let fetch: @Sendable (_ publisherID: String) async throws -> (
        thumbnails: [URL],
        previews: [URL],
        files: [(url: URL, contentType: String, filename: String, isUncompressedFITS: Bool)],
        artifacts: [(uri: String, productType: String?, contentType: String?, contentLength: Int64?, filename: String, downloadURL: URL?)],
        packageDownloadURL: URL?
    )

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let r = try await fetch(args.publisher_id)
        let files = r.files.map {
            Output.FileOut(
                url: $0.url.absoluteString,
                contentType: $0.contentType,
                filename: $0.filename,
                isUncompressedFITS: $0.isUncompressedFITS
            )
        }
        let best = files.first(where: { $0.isUncompressedFITS })?.url ?? files.first?.url
        // Always surface the CAOM-2 inventory regardless of whether
        // DataLink also returned downloadable rows. `files` and
        // `caom2Artifacts` are complementary views: DataLink #this
        // gives URLs you can fetch; CAOM-2 gives every artefact the
        // observation owns (science + weight + preview + aux +
        // provenance). Earlier behaviour silently dropped the
        // inventory when DataLink had any rows, which masked
        // sibling products the agent might want to inspect or
        // package-download separately.
        let artifacts = r.artifacts.map {
            Output.ArtifactOut(
                uri: $0.uri,
                productType: $0.productType,
                contentType: $0.contentType,
                contentLength: $0.contentLength,
                filename: $0.filename,
                downloadURL: $0.downloadURL?.absoluteString
            )
        }
        return Output(
            thumbnails: r.thumbnails.map(\.absoluteString),
            previews: r.previews.map(\.absoluteString),
            files: files,
            bestDirectFileURL: best,
            caom2Artifacts: artifacts,
            packageDownloadURL: r.packageDownloadURL?.absoluteString
        )
    }
}
