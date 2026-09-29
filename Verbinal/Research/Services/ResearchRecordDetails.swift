// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What a Research record says about an observation, from the archive's
/// own record of the plane its file belongs to.
///
/// A record names its plane by publisher ID, and whoever keeps it may
/// describe it too — an assistant passing a filter, a target, a preview.
/// Those descriptions were kept as given, so a record could say g band for
/// a u-band file (the M31 MegaPipe tile). The archive's word now comes
/// first; a description fills only what the archive does not say, and the
/// publisher ID what nobody said.
enum ResearchRecordDetails {

    /// The plane `publisherID` names in `observation`: by its product ID;
    /// when the ID names none — `CFHT?1573200`, whose observation has an
    /// `i` and an `o` plane — the plane that holds `file`, the record's
    /// downloaded file, else the only plane (plan 19 R2, QA M2).
    static func plane(of publisherID: PublisherID, in observation: CAOM2Observation,
                      file: String = "") -> CAOM2Observation.Plane? {
        guard publisherID.productID.isEmpty else {
            return observation.planes.first { $0.productID == publisherID.productID }
        }
        if !file.isEmpty, let holding = observation.planes.first(where: { $0.artifacts.contains { sameFile($0.uri, file) } }) {
            return holding
        }
        return observation.planes.count == 1 ? observation.planes.first : nil
    }

    /// An artifact's file and a file on this computer are the same, compressed
    /// or not: `cadc:CFHT/1573200o.fits.fz` and `1573200o.fits`.
    static func sameFile(_ artifactURI: String, _ file: String) -> Bool {
        func stem(_ name: String) -> String {
            var name = name.lowercased()
            while let suffix = [".fz", ".gz"].first(where: name.hasSuffix) { name.removeLast(suffix.count) }
            return name
        }
        let name = artifactURI.split(separator: "/").last.map(String.init) ?? artifactURI
        return stem(name) == stem(file)
    }

    /// `described`, its details taken from `observation` — the archive's
    /// record of it, when it could be fetched — where the archive says
    /// them, and its collection and observation ID from its publisher ID
    /// where nothing does.
    static func completing(_ described: DownloadedObservation, from observation: CAOM2Observation?,
                           endpoints: APIEndpoints = TAPConfig.endpoints) -> DownloadedObservation {
        var record = described
        let id = PublisherID(described.publisherID)
        var plane: CAOM2Observation.Plane?
        if let id, let observation {
            let file = described.localPath.isEmpty ? "" : URL(fileURLWithPath: described.localPath).lastPathComponent
            plane = Self.plane(of: id, in: observation, file: file)
        }

        func first(_ values: String?...) -> String? { values.compactMap { $0 }.first { !$0.isEmpty } }
        record.collection = first(observation?.collection, described.collection, id?.collection) ?? ""
        record.observationID = first(observation?.observationID, described.observationID, id?.observationID) ?? ""
        record.targetName = first(observation?.target?.name, described.targetName) ?? ""
        record.instrument = first(observation?.instrument?.name, described.instrument) ?? ""
        guard let plane else { return record }

        record.filter = first(plane.energy?.bandpassName, described.filter) ?? ""
        record.calLevel = first(plane.calibrationLevel.map(String.init), described.calLevel) ?? ""
        record.startDate = first(plane.time?.lowerMJD.map { "\($0)" }, described.startDate) ?? ""
        if let polygon = plane.position?.polygon, !polygon.isEmpty {
            let centre = SkyGeometry.centroid(polygon.map { SkyPoint(ra: $0.ra, dec: $0.dec) })
            record.ra = "\(centre.ra)"
            record.dec = "\(centre.dec)"
        }
        // The plane's own pictures, not a sibling's.
        func picture(_ type: String) -> String? {
            plane.artifacts.first { $0.productType?.lowercased() == type }
                .flatMap { endpoints.dataPubURL(forArtifactURI: $0.uri)?.absoluteString }
        }
        record.previewURL = picture("preview") ?? described.previewURL
        record.thumbnailURL = picture("thumbnail") ?? described.thumbnailURL
        return record
    }
}
