import Testing
import Foundation
@testable import ClipnpasteCore

@MainActor @Suite struct InMemoryClipStoreTests {
    @Test func sameHashBumpsToFront() {
        let store = InMemoryClipStore(clips: DemoClips.make())
        let n = store.count
        let old = store.ordered(n).last!
        store.insertOrBump(Clip(kind: .text, plainText: old.plainText, contentHash: old.contentHash))
        #expect(store.count == n)
        #expect(store.ordered(1).first?.id == old.id)
    }

    @Test func moveKeepsOthersInOrder() {
        let store = InMemoryClipStore(clips: DemoClips.make())
        let before = store.ordered(100).map(\.id)
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        store.move(id: before[0], toIndex: 5)
        var expected = before
        expected.remove(at: 0)
        expected.insert(before[0], at: 5)
        #expect(store.ordered(100).map(\.id) == expected)
        #expect(changes == [.moved(before[0])])
    }

    @Test func newCopyLandsFirstAfterMove() {
        let store = InMemoryClipStore(clips: DemoClips.make())
        let ids = store.ordered(100).map(\.id)
        store.move(id: ids[3], toIndex: 0)
        let fresh = Clip(kind: .text, plainText: "fresh", contentHash: DemoClips.hash("fresh"))
        store.insertOrBump(fresh)
        #expect(store.ordered(1).first?.id == fresh.id)
        #expect(store.ordered(2).last?.id == ids[3])
        #expect(store.newestByDate(1).first?.id == fresh.id)
    }
}
