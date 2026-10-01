// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// An element as the hint tools report it.
struct UITargetView: Encodable, Sendable, Equatable {
    let id: String
    /// A hand tag: the same across runs, languages and redesigns.
    let stable: Bool
    let kind: String
    let name: String?
    var help: String?
    let screen: String
    var area: String?
    /// The list item it belongs to, by name.
    var item: String?
    let enabled: Bool
    /// A folded section or a menu, shut: `open_ui` opens it.
    var closed: Bool?
    /// False when it is scrolled out of sight: a hint brings it into view.
    var inSight: Bool?
    /// x, y, width, height in its window's points — where it lies, for one
    /// out of sight.
    let at: [Int]

    init(_ element: UIElement) {
        id = element.id
        stable = element.stable
        kind = element.kind.rawValue
        name = element.name
        help = element.help
        screen = element.screen
        area = element.area
        item = element.item
        enabled = element.enabled
        closed = element.closed ? true : nil
        inSight = element.inSight ? nil : false
        let v = element.inSight ? element.visible : element.frame
        at = [v.minX, v.minY, v.width, v.height].map { Int($0.rounded()) }
    }
}

/// Which elements an assistant names from, and which one a name means — one
/// place for listing, pointing and hinting (plan 27).
enum UITargetScope {
    enum Kind: String, Codable, Sendable {
        /// The controls a person acts on.
        case interactive
        case text
        /// Everything the person can see.
        case all
    }

    /// The window in front — a sheet over its window, Settings over the
    /// app — or every window.
    static func elements(_ snapshot: UISnapshot, window: String?) -> [UIElement] {
        guard window != "all", let front = snapshot.front else { return snapshot.elements }
        return snapshot.elements(in: front.index)
    }

    static func filter(_ elements: [UIElement], kind: Kind, screen: String?, contains: String?) -> [UIElement] {
        let prefix = screen?.lowercased()
        let words = contains.map(UIPointerMatcher.normalise).flatMap { $0.isEmpty ? nil : $0 }
        return elements.filter { element in
            let kindFits = switch kind {
            case .interactive: element.kind.isControl
            case .text: element.kind == .text
            case .all: true
            }
            return kindFits
                && prefix.map(element.screen.lowercased().hasPrefix) ?? true
                && words.map { UIPointerMatcher.normalise(element.id + " " + (element.name ?? "")).contains($0) } ?? true
        }
    }

    enum Match {
        case found(UIElement)
        /// None, or two equally: what there is, and the closed things it may be behind.
        case missing(candidates: [UIElement], closed: [UIElement])
    }

    /// The one element `target` names — by its id, its name, or words of
    /// them — in the window in front, else anywhere on screen; one scrolled
    /// out of sight counts as much as one in sight, and is brought into view.
    /// Two equal matches is a question, not an answer — whichever of them
    /// happens to be showing.
    ///
    /// `preferring`: what the call acts on — sections and menus to open, a
    /// list's entries to select. Those are tried first, so "CFHT" opens the
    /// CFHT collection though rows and texts say CFHT too.
    static func match(_ target: String, in snapshot: UISnapshot, preferring kinds: Set<UIElementKind> = []) -> Match {
        let front = elements(snapshot, window: nil)
        let frontAway = snapshot.front.map { snapshot.outOfSight(in: $0.index) } ?? []
        let everywhere = snapshot.elements + snapshot.outOfSight
        let preferred = kinds.isEmpty ? nil
            : best(target, in: (front + frontAway).filter { kinds.contains($0.kind) })
                ?? best(target, in: everywhere.filter { kinds.contains($0.kind) })
        if let found = preferred ?? best(target, in: front + frontAway) ?? best(target, in: everywhere) {
            return .found(found)
        }
        let targets = front.map(Self.target)
        let candidates = UIPointerMatcher.candidates(targets, for: target).compactMap { t in front.first { $0.id == t.id } }
        return .missing(candidates: candidates, closed: Array(front.filter(\.closed).prefix(8)))
    }

    private static func best(_ target: String, in elements: [UIElement]) -> UIElement? {
        UIPointerMatcher.best(elements.map(Self.target), for: target).flatMap { t in elements.first { $0.id == t.id } }
    }

    /// A control in a list item answers to its words with the item's:
    /// "Relaunch notebook1".
    private static func target(_ element: UIElement) -> UIPointerMatcher.Target {
        let words = [element.name, element.item].compactMap { $0 }.joined(separator: " ")
        return .init(id: element.id, label: words, screen: element.screen, control: element.kind.isControl)
    }
}

// MARK: - list_ui_targets

struct ListUITargetsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var kind: UITargetScope.Kind?
        var screen: String?
        var contains: String?
        var window: String?
        var includeScrolled: Bool?
        var limit: Int?
        var cursor: String?
    }

    struct WindowView: Encodable, Sendable {
        let kind: String
        let title: String
        let screen: String
    }

    struct Output: Encodable, Sendable {
        let window: WindowView?
        let count: Int
        let targets: [UITargetView]
        /// Controls with no name to call them by.
        let unnamed: Int
        let next: String?
        /// Why nothing could be read, when the screen cannot be.
        var problem: String? = nil
        /// Panels the person has hidden: open_ui shows one.
        var hiddenPanels: [PanelView] = []
    }

    struct PanelView: Encodable, Sendable {
        let id: String
        let name: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_ui_targets",
        description: "Everything on screen you can point at or hint — every control the person can see, by what it is (`kind`) and what it says (`name`), with its `id`, `screen` and position (`at`: x, y, width, height in its window's points). `stable: true` ids are hand tags that hold across runs and languages; the others hold while the screen stays as listed. By default it lists the controls (`kind: interactive`) in the window in front — a sheet or Settings when one is open; `kind: all` adds text, images and areas, `window: all` every window. A folded section or a menu is listed with `closed: true` and nothing behind it, and a hidden panel in `hiddenPanels`: open_ui opens one on purpose. A tab not showing is not listed: navigate there first. What is in sight is listed; `includeScrolled` adds what is scrolled out of sight inside a list or a form (`inSight: false`) — a hint on it scrolls it into view. 200 at a time: pass `next` back as `cursor`. These are the app's interface — not the marks on a FITS or cube image (list_fits_annotations, list_cube_annotations).",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "kind": { "type": "string", "enum": ["interactive", "text", "all"], "description": "interactive (default): the controls; text; all: everything the person can see." },
            "screen": { "type": "string", "description": "Only this screen's elements, by prefix (\"search\", \"settings.agent\")." },
            "contains": { "type": "string", "description": "Only elements whose id or name holds these words." },
            "window": { "type": "string", "enum": ["front", "all"], "description": "front (default): the window in front; all: every window." },
            "includeScrolled": { "type": "boolean", "description": "Also list what is scrolled out of sight (`inSight: false`); a hint on one brings it into view." },
            "limit": { "type": "integer", "minimum": 1, "maximum": 500 },
            "cursor": { "type": "string", "description": "`next` from the last answer." }
          },
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> UISnapshot
    let hiddenPanels: @Sendable () async -> [PanelView]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let snapshot = await snapshot()
        let panels = await hiddenPanels()
        var scoped = UITargetScope.elements(snapshot, window: args.window)
        if args.includeScrolled == true {
            scoped += args.window == "all" ? snapshot.outOfSight
                : snapshot.front.map { snapshot.outOfSight(in: $0.index) } ?? []
        }
        let listed = UITargetScope.filter(scoped, kind: args.kind ?? .interactive, screen: args.screen, contains: args.contains)
        let start = min(Int(args.cursor ?? "") ?? 0, listed.count)
        let limit = min(max(args.limit ?? 200, 1), 500)
        let page = listed[start..<min(start + limit, listed.count)]
        let front = args.window == "all" ? nil : snapshot.front
        return Output(
            window: front.map { WindowView(kind: $0.kind.rawValue, title: $0.title, screen: $0.screen) },
            count: listed.count,
            targets: page.map(UITargetView.init),
            unnamed: scoped.filter { $0.kind.isControl && $0.name == nil }.count,
            next: start + limit < listed.count ? String(start + limit) : nil,
            problem: snapshot.problem,
            hiddenPanels: panels)
    }
}

// MARK: - show_ui_hints

struct ShowUIHintsTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Hint: Decodable, Sendable {
        let target: String
        var text: String?
        var title: String?
        var style: UIHint.Style?
    }

    struct All: Decodable, Sendable {
        var kind: UITargetScope.Kind?
        var screen: String?
        var contains: String?
    }

    struct Args: Decodable, Sendable {
        var hints: [Hint]?
        var all: All?
        var mode: String?
        var numbered: Bool?
        var dim: Bool?
        var seconds: Double?
        var untilClosed: Bool?
    }

    struct Shown: Encodable, Sendable, Equatable {
        /// As asked for; the element's own id for a ring from `all`.
        let target: String
        let id: String
        /// `bubble` beside it, `ring` alone, or `list`: its words in the hint
        /// list, its element badged with its number.
        let `as`: String
        var number: Int?
    }

    struct Missing: Encodable, Sendable {
        let target: String
        let candidates: [UITargetView]
        /// Closed things on screen it may be behind: open_ui opens one.
        let closed: [UITargetView]
        /// Why it was not shown, when it was found.
        var reason: String? = nil
    }

    struct Output: Encodable, Sendable {
        var set: String?
        var shown: [Shown] = []
        var missing: [Missing] = []
        /// Hints whose words went to the hint list.
        var listed = 0
        /// Rings past the most that are drawn at once.
        var dropped = 0
        var message: String?
    }

    /// At most this many hints with words, and rings, at once.
    static let maxHints = 100
    static let maxRings = 300

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_ui_hints",
        description: "Show the person several things on the interface at once — a ring round each, and for a hint with `text` (and an optional `title`) a bubble with your words beside it. Name each `target` as point_at_ui does: an id or a name from list_ui_targets — one scrolled out of sight is scrolled into view first; one matching none, or two equally, is shown nothing and comes back in `missing` with what there is, and the closed sections or menus it may be behind. `all` rings every control on screen (or every one of a `kind`, `screen`, or with words it `contains`) — a map of the screen; with `hints`, their bubbles go on top. Bubbles never overlap each other or a hinted element, and keep off images; past twelve, or with no room, the words go to a numbered hint list and the element gets a badge (`as: list`). `numbered` numbers them, for a tour; `dim` shades the rest of the window. `mode: add` (default) keeps the hints already up — the same element twice replaces its hint — and `replace` clears them first. Hints go after `seconds` (2–120; default 8 with words, 15 for rings), when the person closes one or presses Esc, when their element scrolls out of sight, or when the screen changes; `untilClosed` waits for the person, for a slow guide they asked for. When the last of a set goes, list_events has a hintsDismissed event. It shows; it never clicks or changes anything. These are hints on the interface — to mark something on a FITS or cube image, kept with its file, use annotate_fits or annotate_cube.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "hints": {
              "type": "array", "maxItems": 100,
              "items": {
                "type": "object",
                "required": ["target"],
                "properties": {
                  "target": { "type": "string", "minLength": 1, "description": "An id or a name from list_ui_targets." },
                  "text": { "type": "string", "maxLength": 280, "description": "Your words beside it." },
                  "title": { "type": "string", "maxLength": 60 },
                  "style": { "type": "string", "enum": ["bubble", "ring"], "description": "bubble (default with text) or ring alone." }
                },
                "additionalProperties": false
              }
            },
            "all": {
              "type": "object",
              "properties": {
                "kind": { "type": "string", "enum": ["interactive", "text", "all"] },
                "screen": { "type": "string" },
                "contains": { "type": "string" }
              },
              "additionalProperties": false
            },
            "mode": { "type": "string", "enum": ["add", "replace"] },
            "numbered": { "type": "boolean" },
            "dim": { "type": "boolean" },
            "seconds": { "type": "number", "minimum": 2, "maximum": 120 },
            "untilClosed": { "type": "boolean" }
          },
          "additionalProperties": false
        }
        """#
    )

    let show: @Sendable (Args) async -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard args.hints?.isEmpty == false || args.all != nil else {
            throw ToolFailureReason.invalidArgument("give `hints`, `all`, or both")
        }
        return await show(args)
    }
}

// MARK: - clear_ui_hints

struct ClearUIHintsTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        var set: String?
        var targets: [String]?
    }

    struct Output: Encodable, Sendable {
        let cleared: Int
        let left: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_ui_hints",
        description: "Take hints down: one `set` (as show_ui_hints answered it), the hints on some `targets`, or, with neither, every hint. It never touches the marks on an image.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "set": { "type": "string" },
            "targets": { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    let clear: @Sendable (Args) async -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output { await clear(args) }
}

// MARK: - point_at_ui

struct PointAtUITool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let target: String
        var message: String?
        var title: String?
        var seconds: Double?
        var untilClosed: Bool?
    }

    struct Output: Encodable, Sendable {
        let pointed: Bool
        var target: String?
        var id: String?
        var set: String?
        var `as`: String?
        /// When the name did not land on exactly one element: what there is.
        var candidates: [UITargetView] = []
        var closed: [UITargetView] = []
        var message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "point_at_ui",
        description: "Show the person where something is: a ring round it and your short `message` beside it — the answer to \"where is that setting?\" being the app pointing at it. Name it by its id or the words on it (list_ui_targets lists what is on screen); if it is scrolled out of sight, it is scrolled into view first. A name matching none — or two equally — points at nothing and returns the candidates, and the closed sections or menus it may be behind, instead of guessing. Each call adds a hint, so a tour is several calls (the same element twice replaces its hint); show_ui_hints puts several up at once. It stays `seconds` (default 8), or with `untilClosed` until the person closes it. It shows; it never clicks or changes anything — pointing at Delete is safe, and the person decides.",
        schema: #"""
        {
          "type": "object",
          "required": ["target"],
          "properties": {
            "target": { "type": "string", "minLength": 1, "description": "An element's id or name." },
            "message": { "type": "string", "maxLength": 280, "description": "A short sentence shown beside it." },
            "title": { "type": "string", "maxLength": 60 },
            "seconds": { "type": "number", "minimum": 2, "maximum": 120, "description": "How long the hint stays (default 8)." },
            "untilClosed": { "type": "boolean", "description": "No countdown: it waits for the person to close it." }
          },
          "additionalProperties": false
        }
        """#
    )

    let show: @Sendable (ShowUIHintsTool.Args) async -> ShowUIHintsTool.Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let shown = await show(.init(
            hints: [.init(target: args.target, text: args.message, title: args.title,
                          style: args.message == nil && args.title == nil ? .ring : .bubble)],
            mode: "add", seconds: args.seconds, untilClosed: args.untilClosed))
        if let first = shown.shown.first {
            return Output(pointed: true, target: first.target, id: first.id, set: shown.set, as: first.as)
        }
        let missing = shown.missing.first
        return Output(pointed: false, candidates: missing?.candidates ?? [], closed: missing?.closed ?? [],
                      message: shown.message ?? (missing?.candidates.isEmpty == false
                          ? "no single element is called \"\(args.target)\"; these are on screen"
                          : "nothing on screen is called \"\(args.target)\" — navigate_to or open_settings first"))
    }
}

// MARK: - select_ui

struct SelectUITool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let target: String
    }

    struct Output: Encodable, Sendable {
        let selected: Bool
        var target: String?
        /// Its id now.
        var id: String?
        var message: String?
        /// When the name did not land on exactly one element: what there is.
        var candidates: [UITargetView] = []
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "select_ui",
        description: "Select an entry of a list — a file in Storage, a row of a list that selects (downloaded observations, images, runs) — as the person's click would, so the screen shows it chosen. Name it as point_at_ui does; one scrolled out of sight is brought into view first. It selects and nothing else: it never presses a button, deletes, loads or launches — those are their own tools, or the person's. A list whose entries do not select (recent launches, recent searches, saved queries: they act through their buttons) answers `selected: false`, saying so: point at the button instead. View state only; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["target"],
          "properties": {
            "target": { "type": "string", "minLength": 1, "description": "An entry's id or name, from list_ui_targets." }
          },
          "additionalProperties": false
        }
        """#
    )

    let select: @Sendable (Args) async -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output { await select(args) }
}

// MARK: - open_ui / close_ui

/// Opens or closes one closed thing on purpose — a folded section, a hidden
/// panel, a menu (plan 27 C): never by a listing or a hint, and never a tab,
/// which is navigated to.
struct OpenCloseUITool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let target: String
    }

    struct Output: Encodable, Sendable {
        let done: Bool
        var target: String?
        var id: String?
        var kind: String?
        /// A menu opened: it waits for the person, who chooses or presses Esc.
        var waiting: Bool?
        /// What appeared behind it, opened.
        var inside: [UITargetView] = []
        var message: String?
        var candidates: [UITargetView] = []
    }

    let definition: AIToolDefinition
    let act: @Sendable (Args) async -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output { await act(args) }

    private static let schema = #"""
        {
          "type": "object",
          "required": ["target"],
          "properties": {
            "target": { "type": "string", "minLength": 1, "description": "A closed section or menu (closed: true in list_ui_targets), or a panel in hiddenPanels — by id or name." }
          },
          "additionalProperties": false
        }
        """#

    static func open(_ act: @escaping @Sendable (Args) async -> Output) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "open_ui",
            description: "Open one closed thing on purpose, to show the person what is inside: a folded section (closed: true), a panel they hid (hiddenPanels: the file browser), or a menu (a pop-up's or menu button's choices). Only that one opens; nothing else is touched, and nothing is pressed or chosen. It answers what appeared (`inside`), to list and hint like the rest. A menu stays open for the person — they choose from it or press Esc, and a hint never chooses for them; while it is open, list_ui_targets reads its items and show_ui_hints points at them. A tab is not opened: navigate there (navigate_to, select_search_tab, open_settings). close_ui closes it again. View state only; no proposal.",
            schema: schema), act: act)
    }

    static func close(_ act: @escaping @Sendable (Args) async -> Output) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "close_ui",
            description: "Close a section, panel or menu you opened with open_ui — or one the person opened, if they asked. The person can always close it too. View state only; no proposal.",
            schema: schema), act: act)
    }
}

// MARK: - open_settings / close_settings

enum SettingsActions {
    struct OpenArgs: Decodable, Sendable { var section: String? }
    struct NoArgs: Decodable, Sendable {}

    static func open(perform: @escaping @Sendable (OpenArgs) async -> String?) -> LiveActionTool<OpenArgs> {
        let ids = SettingsSection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        return LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "open_settings",
                description: "Open Settings at a section, so you can show the person where something is set — then point at the control with point_at_ui (list_ui_targets lists what is there). Nothing is changed: settings are the person's to set, and some (the MCP server and auto-apply, endpoints, the compute image, sign-ins) only they should. Sections: \(SettingsSection.allCases.map(\.rawValue).joined(separator: ", ")).",
                schema: #"""
                {
                  "type": "object",
                  "properties": { "section": { "type": "string", "enum": [\#(ids)] } },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }

    static func close(perform: @escaping @Sendable (NoArgs) async -> String?) -> LiveActionTool<NoArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "close_settings",
                description: "Close the Settings window. Live-applied; no proposal.",
                schema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            perform: perform)
    }
}
