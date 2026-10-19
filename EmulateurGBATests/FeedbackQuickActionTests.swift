//
//  FeedbackQuickActionTests.swift
//  EmulateurGBATests
//
//  The Home Screen quick action under the icon (asked 2026-10-09): declared
//  in Info.plist with the type the handler answers, the mail glyph, and a
//  draft to support whose subject and context lines arrive intact.
//

import Testing
import UIKit
@testable import EmulateurGBA

struct FeedbackQuickActionTests {

    /// The static item is in the built Info.plist, first, with the handler's
    /// own type, its title and subtitle, and the mail glyph.
    @Test func theInfoPlistDeclaresTheItemTheHandlerAnswers() throws {
        let items = try #require(Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems")
                                 as? [[String: Any]], "no quick actions in Info.plist")
        let first = try #require(items.first)
        #expect(first["UIApplicationShortcutItemType"] as? String == FeedbackQuickAction.type)
        #expect(first["UIApplicationShortcutItemTitle"] as? String == "Something wrong?")
        #expect(first["UIApplicationShortcutItemSubtitle"] as? String
                == "Please leave us feedback so we can fix it")
        #expect(first["UIApplicationShortcutItemIconType"] as? String == "UIApplicationShortcutIconTypeMail")
    }

    /// The draft goes to support, with the subject and the three context
    /// values, every one of them surviving the URL's encoding.
    @Test func theDraftGoesToSupportWithItsContext() throws {
        let url = try #require(FeedbackQuickAction.mailURL(version: "1.3.4 (36)", system: "26.1",
                                                           device: "iPhone15,2"))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "mailto")
        #expect(parts.path == "support@retropal.fr")
        let subject = parts.queryItems?.first { $0.name == "subject" }?.value
        let body = try #require(parts.queryItems?.first { $0.name == "body" }?.value)
        #expect(subject == NSLocalizedString("feedback.mail.subject", comment: ""))
        #expect(body.contains("1.3.4 (36)") && body.contains("26.1") && body.contains("iPhone15,2"))
        // A literal newline, not the two characters of its escape.
        #expect(body.contains("\n") && !body.contains("\\n"))
    }

    /// Only our item opens the draft.
    @MainActor
    @Test func anotherItemIsNotHandled() {
        let other = UIApplicationShortcutItem(type: "com.example.other", localizedTitle: "Other")
        #expect(!FeedbackQuickAction.handle(other))
    }
}
