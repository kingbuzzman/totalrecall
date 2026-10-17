import Foundation

/// CFBundleShortVersionString from the tool's Info.plist, which the Makefile embeds in the binary.
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
