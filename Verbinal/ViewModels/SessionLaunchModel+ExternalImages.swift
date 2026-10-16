// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Images from outside the platform's list: a registry's, or one the person typed.
extension SessionLaunchModel {
    // MARK: - External resources

    /// Why the form cannot show `asked`: a size with Flexible, or a size it
    /// does not offer. Nil when it can, or when it has no sizes yet to check.
    func refusal(_ asked: LaunchResources) -> String? {
        if asked.type == "flexible", asked.asksForASize {
            return "cores, ram and gpus are a fixed size: resources \"flexible\" takes none"
        }
        if let refusal = gpuRefusal(asked.gpus) { return refusal }
        for (name, value, offered) in [("cores", asked.cores, coreOptions), ("ram", asked.ram, ramOptions)] {
            if let value, !offered.isEmpty, !offered.contains(value) {
                return "\(name) \(value) is not one the form offers: \(offered.map(String.init).joined(separator: ", "))"
            }
        }
        return nil
    }

    /// Sets the form's resources as its Flexible / Fixed and steppers would.
    func apply(_ asked: LaunchResources) {
        if let type = asked.resolvedType { resourceType = type }
        if let cores = asked.cores { self.cores = cores }
        if let ram = asked.ram { self.ram = ram }
        if let gpus = asked.gpus { self.gpus = min(gpus, 1) }
    }

    // MARK: - External image selection

    /// Drive the form's full type → project → image cascade from a
    /// single `ParsedImage`. Used by surfaces outside the form
    /// (Canfar Images widget, agent tools) so a click in those
    /// places lands on the same model state the user would reach
    /// by walking the pickers manually.
    ///
    /// Cascade order matters — assigning out of order leaves the
    /// model with mismatched lists (e.g. a `selectedImage` that
    /// isn't in the current `images` array because the project
    /// hasn't rebuilt yet). The `didSet` observers do all the
    /// repopulation work; we just trigger them in the right order.
    ///
    /// Resource sliders, session name, and other form state are
    /// preserved — only the image-identity fields change.
    func applyImageSelection(_ image: ParsedImage, preferredType: String? = nil) {
        // Catalogue images bypass the advanced "custom image" mode.
        if useCustomImage { useCustomImage = false }

        // 1. Session type — first cascade step. Honor the type the user was
        // filtering by (`preferredType`) when the image actually supports it;
        // catalogue images are frequently multi-type (e.g. notebook+headless),
        // so the first declared type isn't necessarily the one the user meant.
        // Fall back to the image's primary declared type otherwise. Skip if the
        // image declares no types (cache-only fallback path).
        let imageTypes = image.types.map { $0.lowercased() }
        let chosenType = preferredType
            .map { $0.lowercased() }
            .flatMap { imageTypes.contains($0) ? $0 : nil }
            ?? imageTypes.first
        if let chosenType,
           sessionTypes.contains(chosenType),
           selectedType != chosenType {
            selectedType = chosenType
        }

        // 2. Project — only assign if the rebuilt projects list
        // actually contains it; otherwise stay on whatever the
        // type cascade landed on.
        if projects.contains(image.project),
           selectedProject != image.project {
            selectedProject = image.project
        }

        // 3. Image — prefer the catalogue's instance so identity
        // matches what the picker enumerates. Fall back to the
        // passed-in value when the catalogue can't produce one
        // (e.g. cache-only browse during a Skaha catalogue
        // outage).
        selectedImage = images.first(where: { $0.id == image.id }) ?? image
    }
}
