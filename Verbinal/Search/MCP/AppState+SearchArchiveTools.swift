// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Search: the archive itself — observations, VizieR, the resolver, CAOM2, DataLinks, previews — and the saved and recent lists.
extension AppState {
    // MARK: - Search domain

    func makeSearchObservationsTool(tap: TAPClient,
                                            resolver: TargetResolverService) -> SearchObservationsTool {
        SearchObservationsTool(
            runQuery: { adql, maxRec in
                do {
                    return try await tap.tapQueryRows(adql: adql, maxRec: maxRec)
                } catch let failure as URLError {
                    // Said as the Search screen says it (plan 21 D5).
                    throw ToolFailureReason.backendError(SearchError.describing(failure))
                }
            },
            resolveTarget: { name in
                let result = try await resolver.resolve(target: name, service: .all)
                // CADC's resolver returns RA/Dec as strings — usually
                // decimal degrees but some shapes ship sexagesimal; the
                // Sexagesimal readers take either. Trailing CR/LF is
                // already stripped by the resolver parser (F-12 fix in
                // TAPClient.parseResolverResponse), so a string neither
                // reads means we genuinely failed to resolve. (Closes F-9
                // of the platform review.)
                guard let ra = Sexagesimal.rightAscension(result.coordsRA),
                      let dec = Sexagesimal.declination(result.coordsDec) else {
                    throw ToolFailureReason.targetNotResolved(name)
                }
                return (ra: ra, dec: dec)
            }
        )
    }

    func makeVizierConeSearchTool(tap: TAPClient) -> VizierConeSearchTool {
        VizierConeSearchTool(search: { catalogue, ra, dec, radius, raCol, decCol, columns, max in
            try await tap.vizierConeSearch(
                catalogue: catalogue,
                raDeg: ra, decDeg: dec, radiusDeg: radius,
                raColumn: raCol, decColumn: decCol, columns: columns,
                maxRec: max
            )
        })
    }

    func makeResolveTargetTool(resolver: TargetResolverService) -> ResolveTargetTool {
        ResolveTargetTool(resolve: { name, service in
            let svc = ResolverValue(named: service) ?? .all  // the schema's enum refuses any other name
            let r: ResolverResult
            do {
                r = try await resolver.resolve(target: name, service: svc)
            } catch {
                // CADC's resolver returns non-200 for unknown names
                // and moving solar-system bodies (Europa, Io, …),
                // which `TAPClient.resolveTarget` surfaces as
                // `SearchError.networkError`. Re-tag that as
                // `targetNotResolved` so agents can distinguish
                // "name not in resolver" from "the network is down"
                // — which is exactly what the verbinal-canfar QA
                // pass flagged.
                if case SearchError.networkError = error {
                    throw ToolFailureReason.targetNotResolved(name)
                }
                throw error
            }
            // Resolver-said-OK-but-no-coords. Coordinates may arrive
            // either as plain decimal degrees or sexagesimal strings;
            // try both. If neither parses we treat the target as
            // unresolved, mirroring the SearchObservationsTool path.
            let raDeg = Sexagesimal.rightAscension(r.coordsRA)
            let decDeg = Sexagesimal.declination(r.coordsDec)
            if raDeg == nil || decDeg == nil {
                throw ToolFailureReason.targetNotResolved(name)
            }
            return ResolveTargetTool.Output(
                target: r.target,
                service: r.service,
                raDeg: raDeg,
                decDeg: decDeg,
                raString: r.coordsRA,
                decString: r.coordsDec,
                coordsys: r.coordsys,
                objectType: r.objectType,
                morphologyType: r.morphologyType,
                note: r.objectType == nil ? nil : ResolveTargetTool.objectTypeCaveat
            )
        })
    }

    func makeGetObservationCAOM2Tool(caom2: CAOM2Service) -> GetObservationCAOM2Tool {
        GetObservationCAOM2Tool(fetch: { id in
            try await caom2.fetch(publisherID: id)
        })
    }

    func makeGetDataLinksTool(tap: TAPClient, caom2: CAOM2Service) -> GetDataLinksTool {
        GetDataLinksTool(fetch: { id in
            // Applier-level 30-second wall-clock deadline scoped to
            // the DataLink fetch ONLY. This is the inner of two
            // independent watchdogs (the outer one is the tool-level
            // `GetDataLinksTool.toolTimeoutSeconds == 30`, applied by
            // `JSONReadTool.invoke` around the whole `handle`). The
            // QA review of 2026-05-14 documented a 4-minute silent
            // hang here — same failure class as the upload applier
            // F-2026-05-13-A: the network call neither returns nor
            // throws, so the caller can't distinguish "still working"
            // from "stuck forever". This inner watchdog converts that
            // to a typed timeout error the wiring can react to before
            // the outer tool deadline fires — falling back to the
            // CAOM-2 inventory below, or letting the agent use the
            // per-artefact downloadURL pattern. Keep this 30s in sync
            // with `GetDataLinksTool.toolTimeoutSeconds`.
            let r = try await withApplierTimeout(seconds: 30, label: "get_data_links") {
                try await tap.fetchDataLinks(publisherID: id)
            }
            let files = r.directFiles.map {
                (url: $0.url, contentType: $0.contentType, filename: $0.filename,
                 isUncompressedFITS: $0.isUncompressedFITS)
            }

            // Always consult CAOM-2 for the full inventory. The
            // original design only filled `artifacts` when DataLink
            // was empty (fallback-only), but DataLink's `#this`
            // rows are a SUBSET of CAOM-2 — they're the directly-
            // downloadable URLs. The full record also lists
            // weight maps, previews, auxiliary products, and
            // provenance artefacts that DataLink suppresses. An
            // agent that already has `files` still benefits from
            // knowing what else the observation owns. Caching in
            // `CAOM2Service` (5-min LRU) makes the extra fetch
            // free on the second call. Failure-to-fetch is
            // tolerated: agents still get the DataLink URLs.
            var artifacts: [(uri: String, productID: String, publisherID: String?, productType: String?, contentType: String?,
                             contentLength: Int64?, filename: String, downloadURL: URL?)] = []
            let endpoints = self.endpoints
            if let obs = try? await caom2.fetch(publisherID: id) {
                for plane in obs.planes {
                    for a in plane.artifacts {
                        let filename = (a.uri as NSString).lastPathComponent
                        artifacts.append((
                            uri: a.uri,
                            productID: plane.productID,
                            publisherID: PublisherID.sibling(of: id, product: plane.productID),
                            productType: a.productType,
                            contentType: a.contentType,
                            contentLength: a.contentLength,
                            filename: filename,
                            downloadURL: endpoints.dataPubURL(forArtifactURI: a.uri)
                        ))
                    }
                }
            }
            return (
                thumbnails: r.thumbnails,
                previews: r.previews,
                files: files,
                artifacts: artifacts,
                packageDownloadURL: TAPClient.downloadURL(publisherID: id),
                faults: r.faults
            )
        })
    }

    func makeGetPreviewImageTool(network: NetworkClient, caom2: CAOM2Service) -> GetPreviewImageTool {
        let endpoints = self.endpoints
        return GetPreviewImageTool(
            resolvePreviews: { id in
                // Resolve preview artifacts from the CAOM-2 inventory: each
                // plane carries its bandpass (energy.bandpassName) and its
                // artifacts; keep only previews (productType "preview" or an
                // image/* content type). Band lives in CAOM-2, NOT DataLink
                // rows (verified against IVOA DataLink 1.0). The per-artifact
                // dataPubURL 302-redirects to signed storage; the fetch follows.
                let obs = try await caom2.fetch(publisherID: id)
                var out: [GetPreviewImageTool.PreviewArtifact] = []
                for plane in obs.planes {
                    let band = plane.energy?.bandpassName
                    for a in plane.artifacts {
                        let isPreview = (a.productType?.lowercased() == "preview")
                            || (a.contentType?.lowercased().hasPrefix("image/") ?? false)
                        guard isPreview, let url = endpoints.dataPubURL(forArtifactURI: a.uri) else { continue }
                        out.append(.init(
                            band: band,
                            url: url,
                            contentType: a.contentType,
                            contentLength: a.contentLength,
                            filename: (a.uri as NSString).lastPathComponent
                        ))
                    }
                }
                return out
            },
            fetchImage: { url, maxBytes in
                // Inner watchdog scoped to the fetch only (mirrors get_data_links);
                // its deadline surfaces as a typed backendError naming the tool.
                try await withApplierTimeout(seconds: 30, label: "get_preview_image") {
                    do {
                        let (data, response) = try await network.get(url.absoluteString, accept: "image/*")
                        if data.count > maxBytes {
                            throw GetPreviewImageTool.PreviewFetchError.tooLarge(data.count)
                        }
                        return (data, response.value(forHTTPHeaderField: "Content-Type"))
                    } catch let e as GetPreviewImageTool.PreviewFetchError {
                        throw e
                    } catch let e as NetworkError {
                        switch e {
                        case .unauthorized:
                            throw GetPreviewImageTool.PreviewFetchError.authRequired
                        case .httpError(let code, _) where code == 401 || code == 403:
                            throw GetPreviewImageTool.PreviewFetchError.authRequired
                        case .httpError(let code, _):
                            throw GetPreviewImageTool.PreviewFetchError.http(code)
                        default:
                            throw GetPreviewImageTool.PreviewFetchError.transport(e.localizedDescription)
                        }
                    }
                }
            }
        )
    }

    func makeListRecentSearchesTool(store: RecentSearchStore) -> ListRecentSearchesTool {
        ListRecentSearchesTool(snapshot: { @MainActor in
            store.searches.map { .init(id: $0.id, name: $0.name, savedAt: $0.savedAt, adql: $0.adql) }
        })
    }

    func makeListSavedQueriesTool(store: SavedQueryStore) -> ListSavedQueriesTool {
        ListSavedQueriesTool(snapshot: { @MainActor in
            store.queries.map {
                SavedQueryRow(
                    id: $0.id, name: $0.name, adql: $0.adql,
                    savedAt: $0.savedAt,
                    description: $0.description, tags: $0.tags
                )
            }
        })
    }

    func makeGetSavedQueryTool(store: SavedQueryStore) -> GetSavedQueryTool {
        GetSavedQueryTool(lookup: { @MainActor id in
            guard let q = store.queries.first(where: { $0.id == id }) else { return nil }
            return SavedQueryRow(
                id: q.id, name: q.name, adql: q.adql,
                savedAt: q.savedAt,
                description: q.description, tags: q.tags
            )
        })
    }
}
