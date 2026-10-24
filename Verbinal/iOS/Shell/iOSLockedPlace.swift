// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UIKit

/// A place that needs the person's CANFAR account, while it is not there
/// (plan 49): what the place is for and Sign In; or, with a stored session,
/// that it is being checked or waits for the network. Apple's tab bars say
/// why a place is empty rather than disable it (D1).
struct iOSLockedPlace: View {
    @Environment(AppState.self) private var appState

    let place: AppState.iOSDashboardTab
    let access: iOSPlaceAccess

    /// The platform's page, for those who have not heard of CANFAR (D5).
    static let canfarURL = URL(string: "https://www.canfar.net/")!

    var body: some View {
        Group {
            switch access {
            case .open:
                EmptyView()
            case .checking:
                ProgressView("Checking your sign-in…")
            case .waitingForNetwork:
                ContentUnavailableView {
                    Label("Waiting for the Network", systemImage: "wifi.slash")
                } description: {
                    Text(verbatim: appState.statusMessage)
                } actions: {
                    Button("Try Again") { Task { await appState.initialize() } }
                        .buttonStyle(.bordered)
                }
            case .locked:
                ContentUnavailableView {
                    Label(place.lockedTitle, systemImage: "lock.fill")
                } description: {
                    Text(place.lockedDescription)
                } actions: {
                    Button("Sign In") { appState.showLoginSheet = true }
                        .buttonStyle(.borderedProminent)
                    Link(destination: Self.canfarURL) {
                        Label("About CANFAR", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint(Text("Opens canfar.net in Safari"))
                }
            }
        }
        .navigationTitle(Text(place.title))
    }
}

extension AppState.iOSDashboardTab {
    /// Portal and Compute are the person's CANFAR account; FITS and Cube
    /// read files on the device and need none.
    var needsAccount: Bool {
        switch self {
        case .portal, .compute: return true
        case .fits, .cube: return false
        }
    }

    /// What a locked place says it is for.
    var lockedTitle: LocalizedStringKey {
        switch self {
        case .portal: return "Your CANFAR Sessions"
        case .compute: return "Your Compute Session"
        case .fits, .cube: return ""
        }
    }

    var lockedDescription: LocalizedStringKey {
        switch self {
        case .portal: return "Sign in with your CADC account to see and launch your sessions, follow the platform's load, and check your storage."
        case .compute: return "Sign in with your CADC account to run code on CANFAR and read its results."
        case .fits, .cube: return ""
        }
    }

    /// The place's icon: its symbol, or — locked — drawn grey with a lock at
    /// its corner, for the tab bar and the sidebar alike.
    @MainActor func image(locked: Bool) -> Image {
        locked ? Image(uiImage: iOSLockedSymbol.image(icon)) : Image(systemName: icon)
    }
}

/// A symbol drawn grey with a small lock at its lower corner, kept grey
/// (original rendering) when its tab is selected.
enum iOSLockedSymbol {
    @MainActor private static var made: [String: UIImage] = [:]

    @MainActor static func image(_ symbol: String) -> UIImage {
        if let image = made[symbol] { return image }
        let base = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        let lock = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        guard let base = base?.withTintColor(.systemGray, renderingMode: .alwaysOriginal),
              let lock = lock?.withTintColor(.systemGray, renderingMode: .alwaysOriginal) else { return UIImage() }
        let size = CGSize(width: base.size.width + lock.size.width / 2, height: base.size.height + lock.size.height / 3)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            base.draw(at: CGPoint(x: 0, y: 0))
            let corner = CGRect(x: size.width - lock.size.width, y: size.height - lock.size.height,
                                width: lock.size.width, height: lock.size.height)
            // A clear ring round the lock, so it reads apart from the symbol.
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: corner.insetBy(dx: -2, dy: -2))
            context.cgContext.setBlendMode(.normal)
            lock.draw(in: corner)
        }.withRenderingMode(.alwaysOriginal)
        made[symbol] = image
        return image
    }
}
