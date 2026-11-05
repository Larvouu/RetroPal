import Testing
import Foundation
@testable import EmulateurGBA
/// A .mdf with subchannel data boots only through its .mds (audit 2026-10-27).
struct MdfImportTests {
    func image(sector: Int, userData: Int) -> Data {
        var d = Data(count: 16 * sector + userData + 64)
        d.replaceSubrange((16 * sector + userData)..<(16 * sector + userData + 6), with: [0x01] + Array("CD001".utf8))
        return d
    }
    @Test func subchannelMdfNeedsMds() {
        #expect(GBAROMParser.mdfNeedsItsDescriptor(head: image(sector: 2448, userData: 24)))
        #expect(GBAROMParser.mdfNeedsItsDescriptor(head: image(sector: 2448, userData: 16)))
        #expect(!GBAROMParser.mdfNeedsItsDescriptor(head: image(sector: 2352, userData: 24)))
        #expect(!GBAROMParser.mdfNeedsItsDescriptor(head: image(sector: 2048, userData: 0)))
        #expect(!GBAROMParser.mdfNeedsItsDescriptor(head: Data(count: 100)))
    }
    @Test func mdsTravelsWithItsMdf() {
        let g = DiscImportGrouper.groupNames(["Game.mdf", "Game.mds"], descriptorText: { _ in nil })
        #expect(g.gaps.isEmpty && g.discs.count == 1 && Set(g.discs[0].members) == ["Game.mdf", "Game.mds"], "\(g)")
        let alone = DiscImportGrouper.groupNames(["Game.mds"], descriptorText: { _ in nil })
        #expect(alone.discs.isEmpty && alone.gaps.isEmpty, "a lone .mds is dropped like any sidecar")
    }
}
