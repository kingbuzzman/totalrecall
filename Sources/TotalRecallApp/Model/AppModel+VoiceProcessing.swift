/// Switching the microphone of the recording going on onto voice processing, from the transcript window.
extension AppModel {
    /// Records the microphone through voice processing or not; shown as asked at once, then as the recording reports.
    func useVoiceProcessing(_ isOn: Bool) {
        guard isRecording else { return }
        usesVoiceProcessing = isOn
        engine.useVoiceProcessing(isOn)
    }
}
