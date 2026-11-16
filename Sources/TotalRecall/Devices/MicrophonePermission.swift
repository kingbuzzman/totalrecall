import AVFoundation

/// Returns whether this process may record the microphone, asking the user the first time.
package func requestMicrophoneAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return waitForAnswer { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }
    default:
        return false
    }
}
