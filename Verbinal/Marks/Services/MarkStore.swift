// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os
import VerbinalKit

/// The marks kept with each file — per extension of a multi-extension FITS
/// file — under one spelling of its path, so reopening it finds them.
@Observable
@MainActor
final class MarkStore {
    /// A pathological target, not disk, is what this bounds.
    nonisolated static let maxPerTarget = 500

    /// Where marks of `file` (and `hdu`, for FITS) are kept.
    struct Target: Hashable, Sendable {
        let file: String
        let hdu: Int?

        init(file: URL, hdu: Int?) {
            self.file = FileIdentity.key(file)
            self.hdu = hdu
        }

        fileprivate init(key: String) {
            if let hash = key.lastIndex(of: "#"), let hdu = Int(key[key.index(after: hash)...]) {
                file = String(key[..<hash])
                self.hdu = hdu
            } else {
                file = key
                hdu = nil
            }
        }

        var key: String { hdu.map { "\(file)#\($0)" } ?? file }
    }

    enum Failure: Error, Equatable {
        case invalid(String)
        case full
        case notFound(String)

        var message: String {
            switch self {
            case .invalid(let why): return why
            case .full: return "this file already has \(MarkStore.maxPerTarget) marks"
            case .notFound(let id): return "no mark \"\(id)\" here — list them first"
            }
        }
    }

    private(set) var marksByKey: [String: [Mark]] = [:]
    /// The mark picked out on screen, by viewer.
    var selected: (target: Target, id: String)?

    private let persistence: DiskPersistence<[String: [Mark]]>?

    init(persistence: DiskPersistence<[String: [Mark]]>? = MarkStore.productionPersistence) {
        self.persistence = persistence
        if case .value(let stored) = persistence?.readResult() { marksByKey = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[String: [Mark]]>(
        subdirectory: "Verbinal", fileName: "marks.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "Marks"))

    func marks(on target: Target) -> [Mark] { marksByKey[target.key] ?? [] }

    /// Every target of `file` that has marks (its extensions, for FITS).
    func targets(of file: URL) -> [Target] {
        let wanted = FileIdentity.key(file)
        return marksByKey.keys.map(Target.init(key:)).filter { $0.file == wanted }.sorted { ($0.hdu ?? -1) < ($1.hdu ?? -1) }
    }

    func add(_ mark: Mark, to target: Target) throws(Failure) {
        if let why = mark.problem { throw .invalid(why) }
        var list = marks(on: target)
        guard list.count < Self.maxPerTarget else { throw .full }
        list.append(mark)
        marksByKey[target.key] = list
        save()
    }

    /// Applies `change` to the mark, keeping it only if it stays drawable.
    @discardableResult
    func update(_ id: String, on target: Target, _ change: (inout Mark) -> Void) throws(Failure) -> Mark {
        var list = marks(on: target)
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        var mark = list[index]
        change(&mark)
        if let why = mark.problem { throw .invalid(why) }
        list[index] = mark
        marksByKey[target.key] = list
        save()
        return mark
    }

    func remove(_ id: String, from target: Target) throws(Failure) {
        var list = marks(on: target)
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        list.remove(at: index)
        marksByKey[target.key] = list.isEmpty ? nil : list
        if selected?.target == target, selected?.id == id { selected = nil }
        save()
    }

    /// Removes every mark of `targets`; returns how many went.
    @discardableResult
    func clear(_ targets: [Target]) -> Int {
        var removed = 0
        for target in targets {
            removed += marks(on: target).count
            marksByKey[target.key] = nil
            if selected?.target == target { selected = nil }
        }
        if removed > 0 { save() }
        return removed
    }

    /// A fresh id, unique on `target`.
    func newID(on target: Target) -> String {
        let taken = Set(marks(on: target).map(\.id))
        var n = taken.count + 1
        while taken.contains("m\(n)") { n += 1 }
        return "m\(n)"
    }

    private func save() {
        _ = persistence?.write(marksByKey)
    }
}
