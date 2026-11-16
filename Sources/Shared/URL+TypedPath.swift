package import Foundation

extension URL {
    /// The file at `path` as typed on the command line, with a leading `~` expanded.
    package init(typedPath path: String) {
        self.init(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
