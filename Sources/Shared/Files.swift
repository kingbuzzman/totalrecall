package import Foundation

extension URL {
    /// The file at `path` as typed on the command line, with a leading `~` expanded.
    package init(typedPath path: String) {
        self.init(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// Throws unless the folder `files` go in exists and, without `overwrite`, none of them does yet.
package func checkCanCreate(_ files: [URL], overwrite: Bool) throws {
    guard let first = files.first else { return }
    let directory = first.deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw MessageError("directory \(directory) does not exist")
    }
    for existing in files where FileManager.default.fileExists(atPath: existing.path) && !overwrite {
        throw MessageError("\(existing.path) already exists (use --force to overwrite)")
    }
}
