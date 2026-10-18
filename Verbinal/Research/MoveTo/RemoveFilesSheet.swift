// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
/// Remove File… for a record with several files on this Mac (plan 46): the
/// rows' own Remove buttons are gone, so the record's button asks which.
/// Each says whether a copy stays in storage; a file whose only copy is here
/// starts unchecked.
struct RemoveFilesSheet: View {
    let observation: DownloadedObservation
    var model: ResearchModel
    let close: () -> Void

    @State private var unchecked: Set<String>
    @State private var failure: String?
    @State private var removing = false

    init(observation: DownloadedObservation, model: ResearchModel, close: @escaping () -> Void) {
        self.observation = observation
        self.model = model
        self.close = close
        _unchecked = State(initialValue: Set(Self.files(of: observation).filter { !$0.places.inStorage }.map(\.name)))
    }

    static func files(of observation: DownloadedObservation) -> [KeptFile] {
        observation.allFiles.filter { $0.places.onMac }
    }

    private var files: [KeptFile] { Self.files(of: observation) }
    private var chosen: [KeptFile] { files.filter { !unchecked.contains($0.name) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove Files from This Mac").font(.title3.bold())
                Text(MoveToModel.title(of: observation)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files) { file in
                    Toggle(isOn: Binding(get: { !unchecked.contains(file.name) }, set: { on in
                        if on { unchecked.remove(file.name) } else { unchecked.insert(file.name) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(file.places.inStorage ? "A copy stays in your storage"
                                                       : "Its only copy: removing it loses it")
                                .font(.caption)
                                .foregroundStyle(file.places.inStorage ? Color.secondary : Color.orange)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(removing)
                }
            }
            Text("The observation stays in Research, with its notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? String(localized: "Remove File") : String(localized: "Remove \(chosen.count) Files"),
                       role: .destructive) {
                    Task { await remove() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || removing)
                .pointable("research.removeFiles.run")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func remove() async {
        removing = true
        defer { removing = false }
        for file in chosen {
            do {
                try await model.removeFile(named: file.name, of: observation)
            } catch {
                failure = String(localized: "Could not remove the file: \(error.localizedDescription)")
                return
            }
        }
        close()
    }
}
#endif
