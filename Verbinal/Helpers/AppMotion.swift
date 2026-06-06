// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// App-wide motion vocabulary — the single home for animation curves,
/// transitions, and the Reduce-Motion guard.
///
/// Before this existed the app hardcoded ~7 distinct timings at 7 call
/// sites with no shared constant, and Reduce-Motion was honoured in only
/// one module (AI Guide). These tokens centralise the curves and route
/// every animation through one accessibility guard so callers can never
/// forget it.
///
/// House split: macOS stays snappier/subtler (cross-fade, tiny scale);
/// iOS leans more fluid. The split is encoded here in `#if os` branches so
/// it is tuned in exactly one place — token *values* branch on platform,
/// the API surface does not (this file compiles into BOTH targets).
enum AppMotion {
    // MARK: - Shared curves (identical on both platforms)

    /// The hero spring — AI Guide tile→panel expand/collapse, future
    /// tile→screen heroes. Unifies what used to be two near-identical
    /// springs (0.40/0.82 open vs 0.36/0.85 close) that read as accidental
    /// asymmetry; one symmetric token now.
    static let hero: Animation = .spring(response: 0.38, dampingFraction: 0.83)

    /// Accordions, disclosures, inline editors. Replaces the AI Guide
    /// tool-row `.snappy(0.22)`.
    static let expand: Animation = .snappy(duration: 0.22)

    /// The "quick UI settle" gesture — hover, scroll-to, drag-border. Folds
    /// the three drifted fast eases (0.15 / 0.15 / 0.18) into one value.
    static let quick: Animation = .easeInOut(duration: 0.16)

    /// Toast banner enter/leave.
    static let toast: Animation = .easeInOut(duration: 0.25)

    // MARK: - Platform-tuned curves

    /// Whole-screen mode-switch cross-fade / push. macOS snappier/subtler,
    /// iOS more fluid. (Consumed by the Chrome phase.)
    static let screen: Animation = {
        #if os(macOS)
        .smooth(duration: 0.28)
        #else
        .snappy(duration: 0.32)
        #endif
    }()

    /// Spinner↔content and selector-pane swaps. iOS a touch longer/more
    /// fluid than macOS. (Consumed by the Breadth phase.)
    static let stateSwap: Animation = {
        #if os(macOS)
        .easeInOut(duration: 0.2)
        #else
        .easeInOut(duration: 0.25)
        #endif
    }()

    // MARK: - Reduce-Motion guard

    /// Collapse an animation to instant when Reduce Motion is on.
    ///
    /// The one rule for every `withAnimation` call site: read
    /// `accessibilityReduceMotion` in scope and pass it here, so the block
    /// runs instantly (no spring/slide/parallax) for RM users. Prefer the
    /// `withAppAnimation` wrapper or the `.appAnimation(_:value:)` modifier
    /// over calling this by hand.
    static func resolve(_ a: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : a
    }
}

// MARK: - Standard transitions (all Reduce-Motion-collapsing)

extension AnyTransition {
    /// The universal Reduce-Motion fallback and macOS default — a plain
    /// cross-fade with no spatial movement.
    static var appFade: AnyTransition { .opacity }

    /// Scale-from-origin hero, lifted verbatim from AI Guide's proven
    /// tile→panel expand. Pass the captured tile-frame anchor.
    static func appHeroScale(anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.3, anchor: anchor).combined(with: .opacity)
    }

    /// Whole-screen transition. macOS = opacity + a *tiny* (≤1.5%) scale so
    /// the content settles without "breathing"; iOS = pure opacity here
    /// (the directional slide is `appScreenDirectional` below). Callers must
    /// still gate this on Reduce Motion (→ `.appFade`).
    static var appScreen: AnyTransition {
        #if os(macOS)
        .opacity.combined(with: .scale(scale: 0.99))
        #else
        .opacity
        #endif
    }

    #if os(iOS)
    /// iOS-only directional whole-screen slide. Forward pushes the new screen
    /// in from the trailing edge while the old one exits to leading; back
    /// reverses it — a shallow depth metaphor that reads natural on iOS but
    /// heavy on a desktop dashboard (so macOS keeps the subtle `appScreen`
    /// cross-fade). Always combined with opacity so a height mismatch between
    /// adjacent screens doesn't pop. Callers still gate on Reduce Motion
    /// (→ `.appFade`); under RM there is no directional movement at all.
    static func appScreenDirectional(forward: Bool) -> AnyTransition {
        let insertEdge: Edge = forward ? .trailing : .leading
        let removeEdge: Edge = forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertEdge).combined(with: .opacity),
            removal: .move(edge: removeEdge).combined(with: .opacity)
        )
    }
    #endif
}

// MARK: - Reduce-Motion-aware view modifier

/// Drives `.animation(_:value:)` but nils the animation under Reduce
/// Motion — the single most important accessibility artifact in the motion
/// system, because callers physically cannot forget the guard.
private struct AppAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Reduce-Motion-aware replacement for `.animation(_:value:)`. Reads
    /// `accessibilityReduceMotion` internally and collapses to instant for
    /// RM users — use this instead of a bare `.animation(...)` for every
    /// new app animation.
    func appAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(AppAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Reduce-Motion-aware withAnimation wrapper

/// Reduce-Motion-aware `withAnimation`. The caller supplies the in-scope
/// `accessibilityReduceMotion` value; under RM the block runs instantly
/// (no transaction animation) so slides/springs collapse to a hard cut /
/// cross-fade. Mirrors the AI Guide `reduceMotion ? <instant> : withAnimation`
/// pattern, but in one reusable place.
@discardableResult
@MainActor
func withAppAnimation<Result>(
    _ animation: Animation?,
    reduceMotion: Bool,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(AppMotion.resolve(animation, reduceMotion: reduceMotion), body)
}

// MARK: - Data-state cross-fade container

/// The four boundary states a loading surface can occupy. Keying the
/// cross-fade on this *discriminator* (not on the content's inner data) is
/// what keeps a 15 s poll refresh of an already-loaded list INSTANT while
/// still cross-fading the spinner→content boundary: a poll cycle keeps the
/// state at `.content`, so the value-scoped animation never fires.
enum DataState: Equatable {
    case loading
    case empty
    case error
    case content
}

/// Reusable spinner↔content cross-fade. Wrap the four loading/empty/error/
/// content branches that every dashboard widget, list, and browser repeats
/// by hand, so they all share one curve and one Reduce-Motion guard.
///
/// The cross-fade rides `AppMotion.stateSwap` and fires ONLY on the
/// `state` boundary (loading→content, content→empty, …), never on the
/// content closure re-rendering with fresh poll data — that churn is
/// deliberately left instant (the analysis' #1 trap). Under Reduce Motion
/// the `.appAnimation` modifier nils the curve, so it collapses to an
/// instant swap with no fade.
///
/// Each branch is supplied as a closure and only the one matching `state`
/// is built, so the heavy `content` view is not constructed while loading.
struct DataStateContainer<Loading: View, Empty: View, ErrorView: View, Content: View>: View {
    let state: DataState
    @ViewBuilder var loading: () -> Loading
    @ViewBuilder var empty: () -> Empty
    @ViewBuilder var error: () -> ErrorView
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            switch state {
            case .loading: loading()
            case .empty:   empty()
            case .error:   error()
            case .content: content()
            }
        }
        .transition(.appFade)
        .appAnimation(AppMotion.stateSwap, value: state)
    }
}

// MARK: - iOS sheet chrome

extension View {
    /// Standard iOS sheet chrome — a drag indicator plus sensible detents —
    /// so in-app sheets match the platform's fluid presentation. Matches the
    /// Terms viewer (`LegalViews`), which was the only iOS sheet that already
    /// adopted this. No-op on macOS, where plain sheets are the snappy norm
    /// and these modifiers don't apply.
    ///
    /// `detents` defaults to `[.large]` (a near-full card with a grabber,
    /// right for progress/detail sheets); pass `[.medium, .large]` for sheets
    /// that read well partially raised.
    func iosSheetChrome(_ detents: Set<PresentationDetent> = [.large]) -> some View {
        #if os(iOS)
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}
