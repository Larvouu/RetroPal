//
//  EmulatorScreen.swift
//  EmulateurGBA
//
//  SwiftUI wrapper for the UIKit emulator view controller.
//

import SwiftUI

struct EmulatorScreen: UIViewControllerRepresentable {
    let romURL: URL
    let session: EmulatorSession
    var loadSlot: Int?
    /// User-facing title (used for the screenshot share card).
    var gameTitle: String?
    var onQuit: (() -> Void)?

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let vc = EmulatorViewController(romURL: romURL, session: session)
        vc.loadSlotOnStart = loadSlot
        vc.gameTitle = gameTitle
        vc.onQuit = onQuit
        return vc
    }

    func updateUIViewController(_ uiViewController: EmulatorViewController, context: Context) {
    }
}
