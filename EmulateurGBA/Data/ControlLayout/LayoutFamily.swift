//
//  LayoutFamily.swift
//  EmulateurGBA
//
//  Which of the two geometry families a window belongs to: the phone one,
//  designed on the iPhone 14 Pro and scaled to every other phone, or the
//  tablet one, which the iPad joined on 2026-09-05.
//
//  The family is a function of the WINDOW, never of the device. iPadOS 26
//  no longer honours `UIRequiresFullScreen`: the player can shrink the app
//  to a phone-shaped window beside another, and a phone-shaped window wants
//  the phone layout whatever hardware it runs on. So the one question asked
//  is "is the short side at least `tabletShortSide`", and every tablet
//  branch in the layout code keys on the answer. No iPhone reaches it (the
//  largest short side is the Pro Max's 440), no iPad in full screen misses
//  it (the smallest is the mini's 744), and the 600 in between leaves both
//  sides room.
//
//  Kept free of UIKit so the tests can ask the same question.
//

import CoreGraphics

enum LayoutFamily: Equatable {
    case phone
    case tablet

    /// Below this short side a window lays out as a phone. See the header.
    static let tabletShortSide: CGFloat = 600

    static func of(_ size: CGSize) -> LayoutFamily {
        min(size.width, size.height) >= tabletShortSide ? .tablet : .phone
    }
}
