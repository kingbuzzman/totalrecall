/// The formats the app saves recordings in. Every recording is captured as 48 kHz, 16-bit stereo PCM in a .caf file;
/// any other format is converted from it, as it records.
package enum AudioFormatChoice: String, CaseIterable, Identifiable, Sendable {
    case mp3, m4a, flac, wav, caf

    package static let `default` = AudioFormatChoice.mp3

    package var id: String { rawValue }
    package var fileExtension: String { rawValue }

    package var title: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .flac: "FLAC (lossless)"
        case .wav: "WAV"
        case .caf: "CAF (as recorded)"
        }
    }

    /// What choosing it costs: what converts to it, and roughly how big an hour of it is.
    package var detail: String {
        switch self {
        case .mp3: "Compressed, by ffmpeg (brew install ffmpeg). About 60 MB an hour."
        case .m4a: "Compressed, by macOS. About 60 MB an hour."
        case .flac: "Lossless and compressed, by macOS. About a third to half of CAF's size."
        case .wav: "Uncompressed, rewritten from CAF. About 690 MB an hour."
        case .caf: "Exactly what is recorded, with no conversion. About 690 MB an hour."
        }
    }

    /// Whether saving it needs ffmpeg, as macOS has no encoder for it.
    package var needsFFmpeg: Bool { self == .mp3 }

    /// Shown with the choice in Settings.
    package static let conversionNote = """
        Every format but CAF costs a conversion. Recordings are captured as CAF (48 kHz, 16-bit PCM) and converted \
        while they record, so saving stays quick, but the conversion takes CPU throughout, and one that falls behind \
        is done over when the recording stops. For the best results, use CAF: no conversion and nothing lost. For \
        small files, use M4A, which macOS converts itself.
        """
}
