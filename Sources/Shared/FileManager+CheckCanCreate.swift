package import Foundation

extension FileManager {
    /// Throws unless the folder `files` go in exists and, without `overwrite`, none of them does yet.
    package func checkCanCreate(_ files: [URL], overwrite: Bool) throws {
        guard let first = files.first else { return }
        let directory = first.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MessageError("directory \(directory) does not exist")
        }
        for existing in files where fileExists(atPath: existing.path) && !overwrite {
            throw MessageError("\(existing.path) already exists (use --force to overwrite)")
        }
    }
}
