import Testing
@testable import ClipnpasteCore

@Suite struct CardLayoutTests {
    @Test func fullHD() {
        let l = CardLayout(visibleWidth: 1920, visibleHeight: 1080)
        #expect(l.count == 8)
        #expect(l.cardWidth == 224)
        #expect(l.cardHeight == 140)
        #expect(l.panelHeight == 180)
    }

    @Test func qhd() {
        let l = CardLayout(visibleWidth: 2560, visibleHeight: 1440)
        #expect(l.count == 8)
        #expect(l.cardWidth == 304)
        #expect(l.cardHeight == 200)
        #expect(l.panelHeight == 240)
    }

    @Test func narrowScreenKeepsFourCards() {
        let l = CardLayout(visibleWidth: 900, visibleHeight: 1080)
        #expect(l.count == 4)
    }

    @Test func rowsForHeight() {
        let l = CardLayout(visibleWidth: 1920, visibleHeight: 1080)
        #expect(l.rows(forHeight: l.panelHeight) == 1)
        #expect(l.rows(forHeight: 1080) == 6)
    }
}
