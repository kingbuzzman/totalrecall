/// Audio is read and handed to the recognizers in chunks of this length.
let chunkSeconds = 0.1
/// To tell totalrecall's channel split from a mixed recording, listen until there has been this much sound.
let speakerDetectionSeconds = 1.0
let maxSpeakerDetectionSeconds = 10.0

/// Whether a stereo source has different audio on its two channels (totalrecall's split: you left, everyone else
/// right) rather than the same on both (a mixed or system-only recording). Returns the chunks it read on the way, so
/// they can still be transcribed.
func hasSeparateSpeakers(_ source: any AudioSource) throws -> (Bool, [[[Float]]]) {
    let chunkFrames = Int(source.sampleRate * chunkSeconds)
    var chunks: [[[Float]]] = []
    var (framesRead, soundFrames) = (0, 0)
    while let chunk = try source.read(maxFrames: chunkFrames) {
        chunks.append(chunk)
        let (left, right) = (chunk[0], chunk[1])
        if zip(left, right).contains(where: { $0 != $1 }) { return (true, chunks) }
        framesRead += left.count
        soundFrames += left.count(where: { $0 != 0 })
        if Double(soundFrames) >= source.sampleRate * speakerDetectionSeconds
            || Double(framesRead) >= source.sampleRate * maxSpeakerDetectionSeconds
        {
            return (false, chunks)
        }
    }
    return (false, chunks)
}
