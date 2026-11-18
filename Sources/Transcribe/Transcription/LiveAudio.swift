import Foundation
import Shared

/// A live stream's audio, and the recording of it being written as it goes on, for a transcript that can start over,
/// as when the language is switched part way through a call. Nothing of the audio is kept here: the first transcript
/// reads the stream, as it comes; one started over reads the recording, from its start, following it as it grows,
/// while a thread of its own drains the stream, so the recorder writing it is not held up. The stream then only says
/// when the recording has ended: the recorder finishes the recording before ending the stream.
final class LiveAudio: @unchecked Sendable {
    /// What a reader finds after what it has read: more frames, up to this many in all; the end of the audio; or that
    /// it was asked to stop.
    enum Next: Equatable {
        case frames(Int)
        case ended
        case stopped
    }

    private let stream: WAVStreamReader
    private let recording: RecordingFile?
    /// Guards what follows, and wakes `close()` waiting for the drain to end.
    private let condition = NSCondition()
    private var hasEnded = false
    private var isDraining = false
    private var isClosed = false

    /// `recording`, open from before the recorder can delete it, as it does once it is saved, is the 16-bit PCM CAF
    /// file the recorder writes as the stream goes on, the same audio, frame for frame. Without one, the transcript
    /// cannot start over: the first reader never stops.
    init(stream: WAVStreamReader, recording: FileHandle?) {
        self.stream = stream
        self.recording = recording.map(RecordingFile.init)
    }

    var canStartOver: Bool { recording != nil }

    /// How long the recording lasts so far, in seconds.
    var recordedSeconds: Double {
        guard let recording, let layout = try? recording.layout() else { return 0 }
        return Double(recording.frames(in: layout)) / layout.sampleRate
    }

    /// The stream, as it comes, until it ends, or `shouldStop` says to stop, when the stream starts being drained.
    func streamReader(stopsWhen shouldStop: @escaping @Sendable () -> Bool) -> StreamReader {
        let neverStops: @Sendable () -> Bool = { false }
        return StreamReader(audio: self, shouldStop: canStartOver ? shouldStop : neverStops)
    }

    /// The recording, from its start, as it grows, until the stream has ended and all of it is read, or `shouldStop`
    /// says to stop.
    func recordingReader(stopsWhen shouldStop: @escaping @Sendable () -> Bool) throws -> RecordingReader {
        guard let recording else { throw MessageError("there is no recording to transcribe again") }
        return RecordingReader(audio: self, file: recording, layout: try recording.layout(), shouldStop: shouldStop)
    }

    /// Stops draining the stream, once the read going on returns, so the caller can close it.
    func close() {
        condition.withLock {
            isClosed = true
            while isDraining { condition.wait() }
        }
    }

    private var streamHasEnded: Bool {
        condition.withLock { hasEnded }
    }

    private func streamEnded() {
        condition.withLock {
            hasEnded = true
            condition.broadcast()
        }
    }

    /// Reads the rest of the stream, and drops it, in a thread of its own, until it ends or `close()` is called.
    private func drain() {
        condition.withLock { isDraining = true }
        let thread = Thread { [self] in
            let chunkFrames = max(1, Int(stream.sampleRate * chunkSeconds))
            while (try? stream.read(maxFrames: chunkFrames)) != nil, !condition.withLock({ isClosed }) {}
            condition.withLock {
                hasEnded = true
                isDraining = false
                condition.broadcast()
            }
        }
        thread.name = "totalrecall.transcribe.drain"
        thread.start()
    }

    /// Reads the stream as it comes, by one task at a time; once stopped, the stream is drained.
    final class StreamReader: Reader, @unchecked Sendable {
        private let audio: LiveAudio
        private let shouldStop: @Sendable () -> Bool
        private let lock = NSLock()
        private var stoppedEarly = false

        var sampleRate: Double { audio.stream.sampleRate }
        var channelCount: Int { audio.stream.channelCount }
        /// Whether it stopped, as asked, rather than at the end of the stream.
        var wasStopped: Bool { lock.withLock { stoppedEarly } }

        fileprivate init(audio: LiveAudio, shouldStop: @escaping @Sendable () -> Bool) {
            self.audio = audio
            self.shouldStop = shouldStop
        }

        func read(maxFrames: Int) throws -> [[Float]]? {
            guard !wasStopped else { return nil }
            if shouldStop() {
                lock.withLock { stoppedEarly = true }
                audio.drain()
                return nil
            }
            do {
                guard let chunk = try audio.stream.read(maxFrames: maxFrames) else {
                    audio.streamEnded()
                    return nil
                }
                return chunk
            } catch {
                audio.streamEnded()
                throw error
            }
        }
    }

    /// Reads the recording from its start, waiting at its end for more until the stream has ended, by one task at a
    /// time.
    final class RecordingReader: Reader, @unchecked Sendable {
        private let audio: LiveAudio
        private let file: RecordingFile
        private let layout: RecordingFile.Layout
        private let shouldStop: @Sendable () -> Bool
        private let lock = NSLock()
        private var stoppedEarly = false
        private var position = 0

        var sampleRate: Double { layout.sampleRate }
        var channelCount: Int { layout.channelCount }
        /// Whether it stopped, as asked, rather than at the end of the recording.
        var wasStopped: Bool { lock.withLock { stoppedEarly } }

        fileprivate init(
            audio: LiveAudio,
            file: RecordingFile,
            layout: RecordingFile.Layout,
            shouldStop: @escaping @Sendable () -> Bool
        ) {
            self.audio = audio
            self.file = file
            self.layout = layout
            self.shouldStop = shouldStop
        }

        /// Waits until there is audio after what was read, the recording has ended, or `shouldStop` says to stop,
        /// which it is asked every tenth of a second, and before anything else.
        func next() -> Next {
            while true {
                if shouldStop() { return .stopped }
                // Whether the stream had ended is asked first: the recording is finished before then.
                let hasEnded = audio.streamHasEnded
                let frames = file.frames(in: layout)
                if frames > position { return .frames(frames) }
                if hasEnded { return .ended }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        func read(maxFrames: Int) throws -> [[Float]]? {
            let available: Int
            switch next() {
            case .frames(let frames): available = frames
            case .ended: return nil
            case .stopped:
                lock.withLock { stoppedEarly = true }
                return nil
            }
            let frameCount = min(maxFrames, available - position)
            let chunk = try file.read(frameCount, from: position, in: layout)
            position += frameCount
            return chunk
        }
    }
}

/// Reads a live stream's audio, until it ends or is stopped.
protocol Reader: AudioSource, Sendable {
    /// Whether it stopped, as asked, rather than at the end of the audio.
    var wasStopped: Bool { get }
}

/// The recording the recorder writes as it goes: a 16-bit little-endian linear PCM CAF file, whose audio chunk grows
/// until the file is closed. Read at given places, so one handle serves every reader, and asking how long it is.
struct RecordingFile: Sendable {
    /// Where its audio starts, and how its frames are laid out.
    struct Layout {
        let sampleRate: Double
        let channelCount: Int
        /// Where the first frame is, and where the audio chunk's size is, which is -1 until the file is closed.
        let audioStart: Int
        let sizeOffset: Int
        var bytesPerFrame: Int { 2 * channelCount }
    }

    let handle: FileHandle

    /// Its layout, from its header; throws if it is not a 16-bit little-endian linear PCM CAF file with its audio
    /// chunk started.
    func layout() throws -> Layout {
        guard let header = read(8, at: 0), header.ascii(0..<4) == "caff" else {
            throw MessageError("the recording is not a CAF file")
        }
        var offset = 8
        var format: (sampleRate: Double, channelCount: Int)?
        while let chunk = read(12, at: offset) {
            let (type, size) = (chunk.ascii(0..<4), Int(chunk.bigEndianInt64(at: 4)))
            if type == "data" {
                guard let format else { throw MessageError("the recording has no format") }
                return Layout(
                    sampleRate: format.sampleRate,
                    channelCount: format.channelCount,
                    audioStart: offset + 16,  // after the chunk's header and its edit count
                    sizeOffset: offset + 4
                )
            }
            if type == "desc" {
                guard let description = read(32, at: offset + 12) else { break }
                format = try Self.format(description)
            }
            guard size >= 0 else { break }
            offset += 12 + size
        }
        throw MessageError("the recording has no audio yet")
    }

    /// The sample rate and channels of a CAF audio description, if it is 16-bit little-endian linear PCM.
    private static func format(_ description: Data) throws -> (Double, Int) {
        let sampleRate = Double(bitPattern: UInt64(bitPattern: description.bigEndianInt64(at: 0)))
        let formatID = description.ascii(8..<12)
        let flags = description.bigEndianUInt32(at: 12)
        let channelCount = Int(description.bigEndianUInt32(at: 24))
        let bitsPerChannel = description.bigEndianUInt32(at: 28)
        let (isFloat, isLittleEndian): (UInt32, UInt32) = (1, 2)
        guard formatID == "lpcm", bitsPerChannel == 16, flags & isFloat == 0, flags & isLittleEndian != 0,
            channelCount > 0, sampleRate > 0
        else {
            throw MessageError("the recording is not 16-bit PCM")
        }
        return (sampleRate, channelCount)
    }

    /// The whole frames written so far: up to the end of the file, or of the audio chunk once its size is known.
    func frames(in layout: Layout) -> Int {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        var bytes = Int(info.st_size) - layout.audioStart
        if let size = read(8, at: layout.sizeOffset).map({ Int($0.bigEndianInt64(at: 0)) }), size >= 4 {
            bytes = min(bytes, size - 4)
        }
        return max(0, bytes) / layout.bytesPerFrame
    }

    /// `count` frames from frame `start`, one array per channel; throws if they are not all there.
    func read(_ count: Int, from start: Int, in layout: Layout) throws -> [[Float]] {
        let bytes = count * layout.bytesPerFrame
        guard let data = read(bytes, at: layout.audioStart + start * layout.bytesPerFrame), data.count == bytes else {
            throw MessageError("the recording is cut short")
        }
        let channelCount = layout.channelCount
        return data.withUnsafeBytes { raw in
            (0..<channelCount).map { channel in
                (0..<count).map { frame in
                    let sample = raw.loadUnaligned(fromByteOffset: (frame * channelCount + channel) * 2, as: Int16.self)
                    // As Core Audio reads 16-bit samples.
                    return Float(Int16(littleEndian: sample)) / 32_768
                }
            }
        }
    }

    /// Up to `count` bytes at `offset`, without moving the handle; nil if there are none there.
    private func read(_ count: Int, at offset: Int) -> Data? {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(handle.fileDescriptor, $0.baseAddress, count, off_t(offset)) }
        guard read > 0 else { return nil }
        return data.prefix(read)
    }
}

extension Data {
    fileprivate func ascii(_ range: Range<Int>) -> String {
        String(decoding: self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)], as: UTF8.self)
    }

    fileprivate func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    fileprivate func bigEndianInt64(at offset: Int) -> Int64 {
        Int64(bitPattern: self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) })
    }
}
