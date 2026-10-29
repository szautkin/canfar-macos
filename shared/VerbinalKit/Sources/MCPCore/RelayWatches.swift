// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Tells once when a process exits (plan 52 A1). The relay watches the
/// client that launched it: a client that dies without closing its pipe
/// must not leave the relay behind. Kept alive by its owner; it stops when
/// released.
public final class ProcessExitWatch: Sendable {
    private let source: any DispatchSourceProcess

    public init(pid: pid_t, exited: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler(handler: exited)
        source.resume()
    }

    deinit { source.cancel() }
}

/// Tells whenever an entry of a folder is added, removed or renamed (plan
/// 52 A2): the app writing its sidecar wakes a relay waiting for it, which
/// would otherwise only find it at its next try.
public final class FolderWatch: Sendable {
    private let source: any DispatchSourceFileSystemObject

    /// Nil when the folder cannot be opened for events.
    public init?(directory: URL, changed: @escaping @Sendable () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                           queue: .global(qos: .utility))
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
