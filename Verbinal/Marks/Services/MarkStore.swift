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
/// file — under the file's identity (plan 36 4.2): one every device shares
/// for a file of Research or of the person's storage, else one spelling of
/// its path here. Reopening it, here or there, finds them.
@Observable
@MainActor
final class MarkStore {
    /// A pathological target, not disk, is what this bounds.
    nonisolated static let maxPerTarget = 500

    /// Where marks of `file` (and `hdu`, for FITS) are kept.
    struct Target: Hashable, Sendable {
        let file: String
        let hdu: Int?
        /// Its path here, when `file` is an identity other devices share:
        /// where its marks were kept before (plan 36 4.2), read until moved.
        let before: String?

        @MainActor
        init(file: URL, hdu: Int?) {
            self.file = FileOrigins.shared.identity(of: file)
            self.hdu = hdu
            let path = FileIdentity.key(file)
            before = self.file == path ? nil : path
        }

        fileprivate init(key: String) {
            if let hash = key.lastIndex(of: "#"), let hdu = Int(key[key.index(after: hash)...]) {
                file = String(key[..<hash])
                self.hdu = hdu
            } else {
                file = key
                hdu = nil
            }
            before = nil
        }

        var key: String { hdu.map { "\(file)#\($0)" } ?? file }
        fileprivate var keyBefore: String? { before.map { path in hdu.map { "\(path)#\($0)" } ?? path } }

        static func == (a: Target, b: Target) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
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

    /// Where each change to the marks is recorded, whoever makes it — the
    /// viewers' editor or an assistant's mark tools (plan 23 C).
    private let changes: ChangeLog

    init(persistence: DiskPersistence<[String: [Mark]]>? = MarkStore.productionPersistence,
         changes: ChangeLog = .shared) {
        self.persistence = persistence
        self.changes = changes
        if case .value(let stored) = persistence?.readResult() { marksByKey = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[String: [Mark]]>(
        subdirectory: "Verbinal", fileName: "marks.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "Marks"))

    func marks(on target: Target) -> [Mark] {
        marksByKey[target.key] ?? target.keyBefore.flatMap { marksByKey[$0] } ?? []
    }

    /// Every target of `file` that has marks (its extensions, for FITS).
    func targets(of file: URL) -> [Target] {
        let wanted = FileOrigins.shared.identity(of: file), path = FileIdentity.key(file)
        let found = Set(marksByKey.keys.map(Target.init(key:)).filter { $0.file == wanted || $0.file == path }
            .map { Target(file: file, hdu: $0.hdu) })
        return found.sorted { ($0.hdu ?? -1) < ($1.hdu ?? -1) }
    }

    /// A target's marks kept under its path move to its identity, on its
    /// first change: from then on they follow the file.
    private func moveBefore(_ target: Target) {
        guard let old = target.keyBefore, let kept = marksByKey.removeValue(forKey: old), marksByKey[target.key] == nil else { return }
        marksByKey[target.key] = kept
    }

    func add(_ mark: Mark, to target: Target) throws(Failure) {
        moveBefore(target)
        if let why = mark.problem { throw .invalid(why) }
        var list = marks(on: target)
        guard list.count < Self.maxPerTarget else { throw .full }
        list.append(mark)
        marksByKey[target.key] = list
        save()
        changes.done("add_mark", "mark \(mark.id) on \(Self.describe(target))")
    }

    /// Applies `change` to the mark, keeping it only if it stays drawable.
    @discardableResult
    func update(_ id: String, on target: Target, _ change: (inout Mark) -> Void) throws(Failure) -> Mark {
        moveBefore(target)
        var list = marks(on: target)
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        var mark = list[index]
        change(&mark)
        mark.modifiedAt = Date()
        if let why = mark.problem { throw .invalid(why) }
        list[index] = mark
        marksByKey[target.key] = list
        save()
        changes.done("update_mark", "mark \(id) on \(Self.describe(target))")
        return mark
    }

    func remove(_ id: String, from target: Target) throws(Failure) {
        moveBefore(target)
        var list = marks(on: target)
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        list.remove(at: index)
        marksByKey[target.key] = list.isEmpty ? nil : list
        if selected?.target == target, selected?.id == id { selected = nil }
        save()
        changes.done("remove_mark", "mark \(id) from \(Self.describe(target))")
    }

    /// Removes every mark of `targets`; returns how many went.
    @discardableResult
    func clear(_ targets: [Target]) -> Int {
        var removed = 0
        for target in targets {
            removed += marks(on: target).count
            marksByKey[target.key] = nil
            if let old = target.keyBefore { marksByKey[old] = nil }
            if selected?.target == target { selected = nil }
        }
        if removed > 0 {
            save()
            changes.done("clear_marks", "\(removed) marks from \(targets.map(Self.describe).joined(separator: ", "))")
        }
        return removed
    }

    // MARK: - From another device (plan 36 4.2)

    /// The marks of files every device knows, each file's (and extension's) one set.
    var portableSets: [MarkSet] {
        marksByKey.filter { FileOrigins.isPortable($0.key) }.map { MarkSet(target: $0.key, marks: $0.value) }
    }

    /// Keeps a file's marks as another device has them.
    func keep(_ set: MarkSet) {
        marksByKey[set.target] = set.marks.isEmpty ? nil : set.marks
        save()
        changes.done("update_mark", "the marks on \(Self.describe(Target(key: set.target)))")
    }

    func removeSet(_ key: String) {
        guard marksByKey.removeValue(forKey: key) != nil else { return }
        save()
        changes.done("clear_marks", "the marks on \(Self.describe(Target(key: key)))")
    }

    /// A target by its key, as `describe` names it.
    nonisolated static func describe(target key: String) -> String { describe(Target(key: key)) }

    /// "m31.fits, extension 1" — how a change names a target.
    nonisolated static func describe(_ target: Target) -> String {
        let name = (target.file as NSString).lastPathComponent
        return target.hdu.map { "\(name), extension \($0)" } ?? name
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
