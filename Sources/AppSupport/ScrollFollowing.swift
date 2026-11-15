/// When the transcript follows the latest line: whenever it is at the bottom just before something changes its size, a
/// new line making the content taller, or the strip of words still being recognized below it making the view shorter
/// as it comes or wraps onto another line, it is kept at the bottom. Scrolled up, it stays put. Looking just before each
/// change, while nothing has moved yet, nothing has to be remembered, so nothing can get out of step with where the
/// view is: a mode of following, switched off by whatever moved the view, was switched off by the view getting shorter.
package enum ScrollFollowing {
    /// Where a scroll view is: scrolled down by `offset`, showing `visibleHeight` of `contentHeight`, in points.
    package struct Geometry: Equatable, Sendable {
        package let offset: Double
        package let visibleHeight: Double
        package let contentHeight: Double

        package init(offset: Double, visibleHeight: Double, contentHeight: Double) {
            self.offset = offset
            self.visibleHeight = visibleHeight
            self.contentHeight = contentHeight
        }

        /// At the bottom, or close enough. So is content that fits, and a view not laid out yet, which then opens on
        /// the latest line.
        package var isAtBottom: Bool {
            visibleHeight <= 0 || offset + visibleHeight >= contentHeight - ScrollFollowing.tolerance
        }
    }

    /// How close to the bottom, in points, still counts as at the bottom.
    package static let tolerance = 24.0
}
