import Foundation

/// The repo's VERSION, which the Makefile writes into the Info.plist it embeds in each binary.
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
