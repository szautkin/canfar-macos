// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The complete file already on this computer, as a file a cutout can be
/// cut from: its images, where they are on the sky, and nothing CADC has to
/// be asked.
struct LocalCutoutFile: CutoutFile {
    let artifactID: String
    let footprint: SkyRegion?
    let boundingCircle: SkyRegion?
    /// A cube's wavelengths, metres — it can then be cut by band.
    var bandMin: Double? = nil
    var bandMax: Double? = nil
    var parameters: Set<String> { bandMin == nil ? ["CIRCLE", "POLYGON"] : ["CIRCLE", "POLYGON", "BAND"] }
    var timeMin: Double? { nil }
    var timeMax: Double? { nil }
    var polStates: [String] { [] }
    let images: [String]
    var companions: [CutoutCompanion] = []
}

/// One way of cutting: from the downloaded file, on this computer —
/// instant, offline, repeatable, and the only way for files CADC will not cut.
struct LocalCutoutSource: CutoutSource {
    let url: URL
    let localFile: LocalCutoutFile
    let fitsFile: FITSFile?
    let wholeFileBytes: Int64?
    let unavailable: String?

    var method: CutoutMethod { .local }
    var file: CutoutFile { localFile }

    /// Read `url`'s headers — the pixels are read only when cutting.
    /// `artifactID` names it as CADC does when the file is one CADC offers.
    static func open(_ url: URL, artifactID: String? = nil, artifacts: [String] = []) -> LocalCutoutSource {
        let name = artifactID ?? url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let empty = LocalCutoutFile(artifactID: name, footprint: nil, boundingCircle: nil, images: [])
        let fits: FITSFile
        do {
            fits = try FITSParser.parse(url: url)
        } catch {
            return LocalCutoutSource(url: url, localFile: empty, fitsFile: nil, wholeFileBytes: size,
                                     unavailable: CutoutIssue.unreadable(error.localizedDescription).message)
        }
        let images = FITSCutter.images(of: fits)
        guard !images.isEmpty else {
            let compressed = fits.hdus.contains(where: \.isCompressed)
            return LocalCutoutSource(url: url, localFile: empty, fitsFile: fits, wholeFileBytes: size,
                                     unavailable: compressed
                                        ? "the file is compressed in a way this computer does not cut (it cuts RICE_1 integer fpack images) — cut it with cutBy soda"
                                        : FITSCutter.Failure.noImage.message)
        }
        let corners = images.flatMap(skyCorners)
        let centre = SkyGeometry.centroid(corners)
        let reach = corners.map { SkyGeometry.distance(centre, $0) }.max() ?? 0
        let bounding = SkyRegion.circle(ra: centre.ra, dec: centre.dec, radius: max(reach, 1e-6))
        // One image is its own footprint; a mosaic's is the circle round them all.
        let footprint = images.count == 1 ? SkyRegion.polygon(skyCorners(images[0])) : bounding
        let wavelengths = images.lazy.compactMap(FITSCutter.wavelengths(of:)).first
        return LocalCutoutSource(url: url, localFile: LocalCutoutFile(artifactID: name, footprint: footprint, boundingCircle: bounding,
                                                                      bandMin: wavelengths?.min(), bandMax: wavelengths?.max(),
                                                                      images: images.map(FITSCutter.name(of:)),
                                                                      companions: companions(of: fits, at: url, among: artifacts, except: name)),
                                 fitsFile: fits, wholeFileBytes: size, unavailable: nil)
    }

    /// The observation's other FITS files beside this one on this computer,
    /// each matched image for image — or greyed with why.
    private static func companions(of fits: FITSFile, at url: URL, among artifacts: [String], except own: String) -> [CutoutCompanion] {
        let folder = url.deletingLastPathComponent()
        return Array(Set(artifacts)).sorted().compactMap { id -> CutoutCompanion? in
            let name = CutoutSpec.artifactFileName(id)
            let lower = name.lowercased()
            guard id != own, lower != url.lastPathComponent.lowercased(),
                  [".fits", ".fit", ".fts", ".fits.fz", ".fz"].contains(where: lower.hasSuffix) else { return nil }
            let path = folder.appendingPathComponent(name)
            guard FileManager.default.isReadableFile(atPath: path.path) else { return nil }
            let unavailable: String?
            do {
                switch FITSCutter.companionImages(of: fits, in: try FITSParser.parse(url: path)) {
                case .success: unavailable = nil
                case .failure(let problem): unavailable = problem.message
                }
            } catch {
                unavailable = CutoutIssue.unreadable(error.localizedDescription).message
            }
            return CutoutCompanion(artifactID: id, fileName: name, unavailable: unavailable)
        }
    }

    /// The image's corners on the sky.
    private static func skyCorners(_ hdu: FITSHDUnit) -> [SkyPoint] {
        guard let wcs = hdu.wcs else { return [] }
        let w = Double(hdu.header.naxis1) - 0.5, h = Double(hdu.header.naxis2) - 0.5
        // A cube's WCS is read for its first two axes.
        return [(-0.5, -0.5), (w, -0.5), (w, h), (-0.5, h)].map {
            let sky = wcs.pixelToWorld(x: $0.0, y: $0.1)
            return SkyPoint(ra: sky.ra, dec: sky.dec)
        }
    }

    /// The rules, then the cutter's own plan: the region has to fall on an image, and the images named have to be there.
    func check(_ spec: CutoutSpec) -> CutoutCheck {
        let common = CutoutRules.check(spec, against: localFile)
        guard common.isValid, let fitsFile, let region = spec.region else { return common }
        do {
            _ = try FITSCutter.plan(fitsFile, region: region, images: spec.extensions, band: (spec.bandMin, spec.bandMax))
            return common
        } catch {
            return CutoutCheck(errors: common.errors + [Self.issue(error)], warnings: common.warnings)
        }
    }

    /// Exact: the boxes' pixels and a header block each (and the primary's).
    func estimatedBytes(_ spec: CutoutSpec) -> Int64? {
        guard let fitsFile, let region = spec.region,
              let parts = try? FITSCutter.plan(fitsFile, region: region, images: spec.extensions,
                                               band: (spec.bandMin, spec.bandMax)) else { return nil }
        func blocks(_ bytes: Int) -> Int { (bytes + 2879) / 2880 * 2880 }
        let data = parts.reduce(0) { total, part in
            let header = fitsFile.hdus.first { $0.id == part.index }?.header
            let bpp = abs(header?.bitpix ?? 8) / 8
            let planes = part.channels?.count ?? (header?.naxis == 3 ? header?.int("NAXIS3") ?? 1 : 1)
            return total + 2880 + blocks(part.box.width * part.box.height * bpp * planes)
        }
        return Int64(data + (parts.contains { $0.index == 0 } ? 0 : 2880))
    }

    static func issue(_ failure: FITSCutter.Failure) -> CutoutIssue {
        switch failure {
        case .offImage: return .outsideFootprint
        case .unknownImage(let name, let available): return .unknownImage(name, available: available)
        case .noWavelengths: return .noBand
        case .outsideBand: return .bandOutside
        case .noImage, .unreadable: return .unreadable(failure.message)
        }
    }
}

/// A cutout cut on this computer from the complete file.
struct LocalCutoutMaker: CutoutMaker {
    /// The complete file of an observation, when it is here.
    let file: @MainActor @Sendable (String) -> URL?
    var method: CutoutMethod { .local }

    func make(publisherID: String, spec: CutoutSpec) async throws -> CutoutFiles {
        guard let url = await file(publisherID) else {
            throw CutoutFailure.noService("the observation's file is not on this computer — download it, or cut it on CADC's side")
        }
        guard let region = spec.region else { throw CutoutFailure.refused(CutoutIssue.nothingToCut.message) }
        return try await Task.detached(priority: .userInitiated) {
            let didScope = url.startAccessingSecurityScopedResource()
            defer { if didScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let fits = try FITSParser.parse(from: data, url: url)
            let cut: Data
            let parts: [FITSCutter.Part]
            do {
                parts = try FITSCutter.plan(fits, region: region, images: spec.extensions, band: (spec.bandMin, spec.bandMax))
                cut = try FITSCutter.cut(data, file: fits, parts: parts, history: "Verbinal cutout of \(url.lastPathComponent)")
            } catch {
                throw CutoutFailure.refused((error as? FITSCutter.Failure)?.message ?? error.localizedDescription)
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(spec.fileName)
            try cut.write(to: target, options: .atomic)
            // Each companion: the same boxes of its images on the same pixels, named by the same key.
            var companions: [URL] = []
            for id in spec.companions {
                let name = CutoutSpec.artifactFileName(id)
                let path = url.deletingLastPathComponent().appendingPathComponent(name)
                let companionData = try Data(contentsOf: path, options: .mappedIfSafe)
                let companion = try FITSParser.parse(from: companionData, url: path)
                guard case .success(let images) = FITSCutter.companionImages(of: fits, in: companion) else {
                    throw CutoutFailure.refused("\(name) is not on the same pixels as \(url.lastPathComponent)")
                }
                let companionCut: Data
                do {
                    companionCut = try FITSCutter.cut(companionData, file: companion,
                                                      parts: FITSCutter.companionParts(parts, images: images, in: companion),
                                                      history: "Verbinal cutout of \(name), with \(url.lastPathComponent)")
                } catch {
                    throw CutoutFailure.refused((error as? FITSCutter.Failure)?.message ?? error.localizedDescription)
                }
                let companionTarget = FileManager.default.temporaryDirectory.appendingPathComponent(spec.fileName(for: name))
                try companionCut.write(to: companionTarget, options: .atomic)
                companions.append(companionTarget)
            }
            return CutoutFiles(cutout: target, companions: companions)
        }.value
    }
}

enum CutoutSources {
    /// The way of cutting a person would want, of those that can: this
    /// computer when the file is here, else CADC.
    static func preferred(_ sources: [any CutoutSource]) -> (any CutoutSource)? {
        sources.first { $0.method == .local && $0.unavailable == nil } ?? sources.first { $0.unavailable == nil } ?? sources.first
    }

    /// The ways an observation's files can be cut: its downloaded file on
    /// this computer — named as CADC names it when CADC offers the same file
    /// — then CADC's.
    static func combine(local: URL?, soda: [SodaCutoutSource], artifacts: [String] = []) -> [any CutoutSource] {
        guard let local else { return soda }
        let name = local.lastPathComponent.lowercased()
        let match = soda.first { $0.file.fileName.lowercased() == name }
            .map(\.file.artifactID) ?? artifacts.first { CutoutSpec.artifactFileName($0).lowercased() == name }
        return [LocalCutoutSource.open(local, artifactID: match, artifacts: artifacts)] + soda
    }
}
