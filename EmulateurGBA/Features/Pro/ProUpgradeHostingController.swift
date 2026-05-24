//
//  ProUpgradeHostingController.swift
//  EmulateurGBA
//
//  UIHostingController wrapper for presenting ProUpgradeView from UIKit.
//

import SwiftUI

final class ProUpgradeHostingController: UIHostingController<ProUpgradeView> {
    private var onDismissAction: (() -> Void)?

    init(context: ProPromptContext = .tappedLockedFeature, onDismiss: (() -> Void)? = nil) {
        self.onDismissAction = onDismiss
        super.init(rootView: ProUpgradeView(context: context))
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismissAction?()
    }
}
