import Foundation

// Checking and requesting the System Audio Recording permission uses UNDOCUMENTED API.
//
// Apple offers no public way to check or request this permission (unlike the microphone's). Officially, macOS asks
// the first time an app starts recording from a process tap, and if the permission is missing, the tap delivers pure
// silence with no error: indistinguishable from nothing playing. To fail clearly instead, this calls into TCC, the
// private framework behind macOS's privacy permissions, the way Guilherme Rambo's AudioCap sample does
// (https://github.com/insidegui/AudioCap): `TCCAccessPreflight` reports the status of a service without prompting,
// and `TCCAccessRequest` shows the system prompt. The service is "kTCCServiceAudioCapture", the "System Audio Recording
// Only" list in System Settings. For a command-line tool, TCC answers for the app it was started from, such as
// Terminal.
//
// Apple can change or remove these functions in any macOS release. They are looked up at runtime, so if they are
// gone, totalrecall records without checking, as before, instead of failing to launch.

private let tccFramework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private let audioCaptureService = "kTCCServiceAudioCapture" as CFString

/// `int TCCAccessPreflight(CFStringRef service, CFDictionaryRef options)`: 0 granted, 1 denied, anything else unknown.
private typealias TCCAccessPreflight = @convention(c) (CFString, CFDictionary?) -> Int32
/// `void TCCAccessRequest(CFStringRef service, CFDictionaryRef options, void (^completion)(Bool granted))`.
private typealias TCCAccessRequest =
    @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void)
    -> Void

private func tccFunction<Function>(_ name: String, as type: Function.Type) -> Function? {
    guard let tccFramework, let symbol = dlsym(tccFramework, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

/// Returns whether this process may record system audio, requesting the permission when it is not granted: the system
/// prompt appears if the user has not answered it yet. Also true when the undocumented API is unavailable, since the
/// permission cannot be checked then.
func requestSystemAudioAccess() -> Bool {
    guard
        let preflight = tccFunction("TCCAccessPreflight", as: TCCAccessPreflight.self),
        let request = tccFunction("TCCAccessRequest", as: TCCAccessRequest.self)
    else { return true }
    if preflight(audioCaptureService, nil) == 0 { return true }
    let answered = DispatchSemaphore(value: 0)
    var granted = false
    request(audioCaptureService, nil) { answer in
        granted = answer
        answered.signal()
    }
    answered.wait()
    return granted
}
