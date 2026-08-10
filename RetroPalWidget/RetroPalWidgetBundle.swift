//
//  RetroPalWidgetBundle.swift
//  RetroPalWidget
//
//  "Récents" needs no configuration and is the only widget iOS 16 can offer.
//  The two configurable ones are iOS 17+ (see RetroPalWidgetIntents), so they
//  join the bundle only where the system can actually configure them.
//

import WidgetKit
import SwiftUI

@main
struct RetroPalWidgetBundle: WidgetBundle {
    var body: some Widget {
        // WidgetBundleBuilder can only ADD by OS version, never remove:
        // `if #available` works (buildLimitedAvailability), but if/else and
        // #unavailable are rejected outright — a bundle cannot drop a widget on
        // a newer OS. So Recents cannot be hidden on iOS 17 the way it was
        // requested; the only alternative is deleting it entirely, which would
        // leave iOS 16 (iPhone 8 / X, our deliberate floor) with no widget at
        // all. Keeping all three is the lesser cost: one extra row in a gallery
        // people visit once, against a whole segment losing the feature.
        RetroPalWidget()
        if #available(iOS 17.0, *) {
            RetroPalGameWidget()
            RetroPalGamesWidget()
        }
    }
}
