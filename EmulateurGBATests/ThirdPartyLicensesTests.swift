//
//  ThirdPartyLicensesTests.swift
//  EmulateurGBATests
//
//  The third-party licences page is how the app gives the notices its
//  components' licences ask for. A block that names a text the bundle does not
//  carry shows an empty page, which reads as the notice being given while it
//  is not. Added with the PSP's components (2026-10-10), which brought the
//  first new licence text since the PlayStation (libpng 1.7's own licence).
//

import Testing
import Foundation
@testable import EmulateurGBA

struct ThirdPartyLicensesTests {

    @Test func everyNamedLicenceTextIsInTheBundle() {
        for licence in ThirdPartyLicense.all where licence.file != nil {
            let text = licence.text ?? ""
            #expect(text.count > 200, "\(licence.id): its text \(licence.file ?? "") is missing or empty")
        }
    }

    @Test func blockIdsAreUnique() {
        let ids = ThirdPartyLicense.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
