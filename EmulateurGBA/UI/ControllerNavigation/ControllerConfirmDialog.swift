//
//  ControllerConfirmDialog.swift
//  EmulateurGBA
//
//  The app's own confirmation dialog, used instead of a system alert while a
//  controller is in hand (`ControllerAlert.present`).
//
//  WHY NOT THE SYSTEM ALERT. iOS gives an app one lever over an alert's
//  buttons, `preferredAction`, which draws one of them bold, and nothing to
//  put a highlight on them. The first version moved that bold action with the
//  D-pad, and on device it could not be read: a preferred Cancel is drawn blue
//  and filled, a preferred destructive "Overwrite" is drawn exactly as before,
//  so the choice looked stuck on Cancel (device report, 2026-09-27, on the
//  pause menu's save and load confirmations). This dialog is plain buttons, so
//  the controller's ring sits on the chosen one like everywhere else.
//
//  It wears the library's panel look (a dimmed page, a dark card), whatever
//  the theme, with the same words and the same actions the alert had: A does
//  what a tap does, B takes the cancel action when there is one. A dialog
//  with no cancel action (the Nintendo 64's lost picture) cannot be dismissed
//  with B, exactly as its alert could not.
//

import UIKit

final class ControllerConfirmDialog: UIViewController {
    struct Action {
        let title: String
        let style: UIAlertAction.Style
        let handler: () -> Void
    }

    private let titleText: String?
    private let message: String?
    private let actions: [Action]

    init(title: String?, message: String?, actions: [Action]) {
        self.titleText = title
        self.message = message
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 0.97)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        view.addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let titleText {
            let label = UILabel()
            label.text = titleText
            label.font = .preferredFont(forTextStyle: .headline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        if let message {
            let label = UILabel()
            label.text = message
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor.white.withAlphaComponent(0.78)
            label.textAlignment = .center
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(18, after: label)
        }

        // The choices first, the cancel last, each on its own full-width row:
        // a long language wraps instead of being cut (rule 8).
        let ordered = actions.filter { $0.style != .cancel } + actions.filter { $0.style == .cancel }
        var cancelButton: UIButton?
        for action in ordered {
            let button = makeButton(for: action)
            stack.addArrangedSubview(button)
            if action.style == .cancel { cancelButton = button }
        }

        // What B does: the cancel action, when the dialog has one.
        if let cancel = actions.first(where: { $0.style == .cancel }) {
            let back = FocusProbeView()
            back.config.back = { [weak self] in self?.finish(with: cancel) }
            back.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(back)
            NSLayoutConstraint.activate([
                back.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                back.topAnchor.constraint(equalTo: card.topAnchor),
                back.widthAnchor.constraint(equalToConstant: 1),
                back.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        // A controller reaches the buttons; its highlight starts on the cancel
        // action, the one that changes nothing, else on the first choice.
        ControllerNavigator.shared.registerUIKitRoot(card, preferred: cancelButton ?? stack.arrangedSubviews
            .first { $0 is UIButton })
    }

    private func makeButton(for action: Action) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = action.title
        config.titleAlignment = .center
        config.cornerStyle = .fixed
        config.background.cornerRadius = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        switch action.style {
        case .destructive:
            config.baseBackgroundColor = .systemRed
            config.baseForegroundColor = .white
        case .cancel:
            config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.12)
            config.baseForegroundColor = .white
        default:
            config.baseBackgroundColor = LandscapeThemeStore.shared.theme.accentUIColor
            config.baseForegroundColor = .white
        }
        let button = UIButton(configuration: config)
        // The ring reads the corner from the layer (`ControllerNavigator`).
        button.layer.cornerRadius = 12
        button.titleLabel?.numberOfLines = 0
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.finish(with: action) }, for: .touchUpInside)
        return button
    }

    /// Close, then run the action, as an alert does.
    private func finish(with action: Action) {
        let handler = action.handler
        dismiss(animated: true) { handler() }
    }
}
