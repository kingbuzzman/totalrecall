import Testing

@testable import AppSupport

struct ScrollFollowingTests {
    @Test(arguments: [
        (0.0, 400.0, 300.0, true),  // the content fits
        (600.0, 400.0, 1_000.0, true),  // right at the bottom
        (580.0, 400.0, 1_000.0, true),  // within the tolerance
        (500.0, 400.0, 1_000.0, false),  // a line or more above it
        (0.0, 400.0, 1_000.0, false),  // at the top
        (0.0, 0.0, 1_000.0, true),  // not laid out yet: it opens on the latest line
    ])
    func tellsWhetherItIsAtTheBottom(offset: Double, visible: Double, content: Double, atBottom: Bool) {
        let geometry = ScrollFollowing.Geometry(offset: offset, visibleHeight: visible, contentHeight: content)

        #expect(geometry.isAtBottom == atBottom)
    }

    @Test func aViewGettingShorterAtTheBottomIsNoLongerAtItUntilScrolled() {
        // Why the table looks before each change: once the live strip has taken 60 points, it no longer is.
        let before = ScrollFollowing.Geometry(offset: 600, visibleHeight: 400, contentHeight: 1_000)
        let after = ScrollFollowing.Geometry(offset: 600, visibleHeight: 340, contentHeight: 1_000)

        #expect(before.isAtBottom)
        #expect(!after.isAtBottom)
    }
}
