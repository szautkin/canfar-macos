// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import Observation

/// Puts hints on screen and keeps them right (plan 27 O): it reads what is
/// on screen, shows hints on elements of that reading, lays each window's
/// hints out by `UIHintLayout`, draws them with `UIHintOverlay`, follows
/// their elements as windows move and scroll, and takes them down when
/// their screen changes, a sheet covers them, or their window closes. The
/// person closes them, pauses one by reading it, or presses Esc.
@MainActor
final class UIHintPresenter {
    /// One hint asked for, on an element of the last reading.
    struct Request {
        let element: UIElement
        let title: String?
        let text: String?
        let style: UIHint.Style
    }

    let store: UIHintStore
    private let source: AXElementSource
    private let screenSignature: @MainActor () -> String
    private let tracker = UIHintTracker()
    private let measure = UIHintMeasure()
    private lazy var overlay = UIHintOverlay(actions: UIHintActions(
        close: { [weak self] in self?.store.close($0) },
        closeAll: { [weak self] in self?.store.clear(window: $0, .closed) },
        hover: { [weak self] in self?.hover($0) }))

    /// The last reading of the screen: what hints are named from, and what
    /// bubbles keep off.
    private(set) var lastSnapshot = UISnapshot.empty
    /// Where each bubble sat relative to its element, so it stays there.
    private var previous: [String: CGRect] = [:]
    private var hovered: String?
    private var clock: Timer?
    private var ticks = 0
    private var keyMonitor: Any?
    private var notes: [NSObjectProtocol] = []
    private var followQueued = false
    private var settle: Task<Void, Never>?

    init(store: UIHintStore, source: AXElementSource, screenSignature: @escaping @MainActor () -> String) {
        self.store = store
        self.source = source
        self.screenSignature = screenSignature
        watchStore()
        watchScreens()
    }

    // MARK: - For the tools

    /// Waits, the first time, for what is on screen to be readable.
    func ready() async { await source.ready() }

    /// What is on screen now.
    func snapshot() -> UISnapshot {
        lastSnapshot = source.snapshot()
        return lastSnapshot
    }

    /// Scrolls those of `elements` (of the last reading) that are out of
    /// sight into view, waits for the scroll to settle, and reads the screen
    /// again (plan 27 V). Answers every one of them as it is now, by its old
    /// id, found again by identity: in sight — or out of it, when bringing
    /// another in scrolled it away — or absent when it is gone.
    func bringIntoView(_ elements: [UIElement]) async -> [String: UIElement] {
        let held = elements.compactMap { element in
            source.element(element.handle).map { (original: element, element: $0) }
        }
        guard held.contains(where: { !$0.original.inSight }) else { return [:] }
        for entry in held where !entry.original.inSight {
            _ = await source.scrollIntoView(entry.original)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let now = snapshot()
        let everything = now.elements + now.outOfSight
        var found: [String: UIElement] = [:]
        for entry in held {
            guard let handle = source.handle(of: entry.element),
                  let current = everything.first(where: { $0.handle == handle }) else { continue }
            found[entry.original.id] = current
        }
        return found
    }

    /// Selects a row or item of the last reading — brought into view first —
    /// as a click selects it. Answers it as it is now, and whether it is.
    func select(_ element: UIElement) async -> (element: UIElement, selected: Bool) {
        var current = element
        if !element.inSight, let moved = await bringIntoView([element])[element.id] { current = moved }
        return (current, await source.select(current))
    }

    /// Opens or closes a closed section or menu of the last reading (plan 27
    /// C) — or opens what a control opens (plan 30 T2) — and reads the
    /// screen again. Answers whether it worked, and the elements that
    /// appeared — what was behind it.
    func setOpen(_ element: UIElement, _ open: Bool) async -> (done: Bool, appeared: [UIElement]) {
        let settles = element.kind == .disclosure ? 100 : element.presents != nil ? 700 : 400
        return await appearing(after: settles) { [source] in
            open ? await source.open(element) : await source.close(element)
        }
    }

    /// Opens an element's right-click menu (plan 30 T2), and reads the screen again.
    func showMenu(_ element: UIElement) async -> (done: Bool, appeared: [UIElement]) {
        await appearing(after: 400) { [source] in source.showMenu(element) }
    }

    /// Closes a right-click menu that is open, as Esc does.
    func cancelOpenMenus() -> Bool { source.cancelOpenMenus() }

    /// Acts, waits for the screen to settle, and reads it again: whether it
    /// worked, and what appeared — found by identity, since derived ids
    /// renumber when rows move.
    private func appearing(after milliseconds: Int, _ act: () async -> Bool) async -> (done: Bool, appeared: [UIElement]) {
        let before = source.everything()
        guard await act() else { return (false, []) }
        try? await Task.sleep(for: .milliseconds(milliseconds))
        let now = snapshot()
        return (true, now.elements.filter { source.element($0.handle).map { !before.contains($0) } ?? false })
    }

    /// Shows hints on elements of the last reading, as one set.
    @discardableResult
    func show(_ requests: [Request], numbered: Bool, dim: Bool, seconds: Double?, replace: Bool) -> String {
        let hints = requests.compactMap { request -> UIHint? in
            guard let window = lastSnapshot.windows.first(where: { $0.index == request.element.window }) else { return nil }
            if let element = source.element(request.element.handle) {
                tracker.follow(request.element.id, .init(element: element,
                                                         clips: request.element.clips.compactMap(source.element),
                                                         window: window.number))
            }
            return UIHint(id: request.element.id, set: "", style: request.style, title: request.title, text: request.text,
                          number: nil, frame: request.element.visible, kind: request.element.kind,
                          screen: request.element.screen, window: window.number)
        }
        let set = store.show(hints, numbered: numbered, dim: dim, seconds: seconds, replace: replace)
        announce(hints)
        return set
    }

    /// Each window's scene as drawn now, for the tools' answers and tests.
    func scene(on window: Int) -> UIHintScene? { overlay.scene(on: window) }

    // MARK: - Drawing

    private func watchStore() {
        withObservationTracking {
            _ = store.hints
            _ = store.sets
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.watchStore()
            }
        }
    }

    func render() {
        let hints = store.hints
        tracker.keep(only: Set(hints.map(\.id)))
        previous = previous.filter { id, _ in hints.contains { $0.id == id } }
        var scenes: [Int: UIHintScene] = [:]
        for (number, onWindow) in Dictionary(grouping: hints, by: \.window) {
            guard let window = NSApp.window(withWindowNumber: number) else { continue }
            let hinted = Set(onWindow.map(\.id))
            let others = lastSnapshot.windows.first { $0.number == number }
                .map { lastSnapshot.elements(in: $0.index).filter { !hinted.contains($0.id) } } ?? []
            let scene = UIHintScene.build(
                hints: onWindow, sets: store.sets, size: window.frame.size,
                controls: others.filter(\.kind.keptClear).map(\.visible),
                images: others.filter { $0.kind == .canvas || ($0.kind == .image && $0.visible.width * $0.visible.height > 40_000) }
                    .map(\.visible),
                previous: previous, measure: measure)
            for bubble in scene.bubbles {
                guard let hint = onWindow.first(where: { $0.id == bubble.id }) else { continue }
                let target = hint.frame.insetBy(dx: -UIHintMeasure.ringOutset, dy: -UIHintMeasure.ringOutset)
                previous[bubble.id] = bubble.frame.offsetBy(dx: -target.minX, dy: -target.minY)
            }
            scenes[number] = scene
        }
        overlay.render(scenes)
        hints.isEmpty ? stopFollowing() : startFollowing()
    }

    // MARK: - Following

    private func startFollowing() {
        guard clock == nil else { return }
        let clock = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc takes the hints down — and nothing else, while they are up.
            guard event.keyCode == 53, let self, !self.store.isEmpty else { return event }
            self.store.clearAll(.escape)
            return nil
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            notes.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followSoon() }
            })
        }
        notes.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let clip = note.object as? NSClipView, let window = clip.window,
                      self.store.hints.contains(where: { $0.window == window.windowNumber }) else { return }
                self.followSoon()
            }
        })
        notes.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                self?.store.clear(window: window.windowNumber, .windowClosed)
            }
        })
        notes.append(center.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // A sheet over a window: the window's hints are not where to look now.
                guard let window = note.object as? NSWindow else { return }
                self?.store.clear(window: window.windowNumber, .screenChanged)
            }
        })
    }

    private func stopFollowing() {
        clock?.invalidate()
        clock = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        notes.forEach(NotificationCenter.default.removeObserver)
        notes = []
        settle?.cancel()
        hovered = nil
    }

    private func tick() {
        ticks += 1
        overlay.trackMouse()
        if ticks % 5 == 0 { store.expire() }
        if ticks % 10 == 0 { follow() }
    }

    /// Once, after the burst of moves and scrolls that asked for it.
    private func followSoon() {
        guard !followQueued else { return }
        followQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.followQueued = false
            self?.follow()
            // When the scrolling stops, read the screen again: what bubbles keep off has moved too.
            self?.settle?.cancel()
            self?.settle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, !self.store.isEmpty else { return }
                _ = self.snapshot()
                self.render()
            }
        }
    }

    private func follow() {
        guard !store.isEmpty else { return }
        let (frames, gone) = tracker.read()
        store.move(frames, gone: gone)
        render()
    }

    private func hover(_ id: String?) {
        guard id != hovered else { return }
        if let hovered { store.resume(hovered) }
        if let id { store.pause(id) }
        hovered = id
    }

    // MARK: - Screens

    /// A hint belongs to the screen it was shown on: when that screen
    /// changes, its hints go.
    private func watchScreens() {
        withObservationTracking {
            _ = screenSignature()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.screenChanged()
                self?.watchScreens()
            }
        }
    }

    private func screenChanged() {
        guard !store.isEmpty else { return }
        let now = snapshot()
        for number in Set(store.hints.map(\.window)) {
            let screen = now.windows.first { $0.number == number }?.screen
            let stale = store.hints.contains { $0.window == number && $0.screen != screen }
            if screen == nil || stale { store.clear(window: number, .screenChanged) }
        }
    }

    // MARK: - VoiceOver

    private func announce(_ hints: [UIHint]) {
        let words = hints.compactMap { [$0.title, $0.text].compactMap { $0 }.joined(separator: ": ") }
            .filter { !$0.isEmpty }.prefix(3).joined(separator: ". ")
        guard !words.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
#endif
