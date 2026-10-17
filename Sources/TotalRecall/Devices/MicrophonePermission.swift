import AVFoundation

/// Returns whether this process may record the microphone, asking the user the first time.
func requestMicrophoneAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false  // written before `answered.signal()`, read after `answered.wait()`
        AVCaptureDevice.requestAccess(for: .audio) { answer in
            granted = answer
            answered.signal()
        }
        answered.wait()
        return granted
    default:
        return false
    }
}
