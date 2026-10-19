//
//  FeedbackQuickAction.swift
//  EmulateurGBA
//
//  The first action under the app's icon on the Home Screen (asked
//  2026-10-09): "Something wrong? Please leave us feedback so we can fix it",
//  with the mail glyph. A long press on the icon is also how an app is
//  deleted, so this is where a player who is about to give up finds a way to
//  tell us why instead.
//
//  The item itself is STATIC, declared in Info.plist
//  (`UIApplicationShortcutItems`, its two lines localized in each
//  InfoPlist.strings), so it is there from the first install, before the app
//  has ever been opened. A tap opens the player's mail app on a draft to
//  support@retropal.fr, its subject and a few lines of context filled in.
//  Nothing is sent until they send it.
//

import UIKit

enum FeedbackQuickAction {
    /// The item's type in Info.plist.
    static let type = "com.retropal.feedback"
    static let address = "support@retropal.fr"

    /// Opens the draft when `item` is ours. Returns whether it was.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == type, let url = mailURL() else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// The draft: a `mailto:` link to support, with the subject and, under the
    /// player's own lines, the version of the app, of iOS, and the device,
    /// which is what a reply needs first.
    static func mailURL(version: String = appVersion, system: String = UIDevice.current.systemVersion,
                        device: String = deviceModel) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        let body = String(format: NSLocalizedString("feedback.mail.body", comment: ""),
                          version, system, device)
        components.queryItems = [
            URLQueryItem(name: "subject", value: NSLocalizedString("feedback.mail.subject", comment: "")),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The hardware identifier ("iPhone15,2"), the same reading the
    /// RetroAchievements user agent makes.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let id = Mirror(reflecting: info.machine).children.reduce(into: "") { acc, element in
            if let value = element.value as? Int8, value != 0 {
                acc.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }
}
