import Foundation

/// The live audio stream between `totalrecall -` and `transcribe -`: WAV of unknown length, the way streaming tools
/// such as ffmpeg and sox write it (RIFF and data sizes of 0xFFFFFFFF), followed by interleaved 16-bit little-endian
/// PCM. Shared by both tools.
package enum WAVStream {
    package static let unknownSize: UInt32 = 0xFFFF_FFFF

    package static func header(sampleRate: Int, channelCount: Int) -> Data {
        let bytesPerFrame = channelCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(unknownSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))  // PCM
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * bytesPerFrame))
        data.appendLittleEndian(UInt16(bytesPerFrame))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(unknownSize)
        return data
    }

    /// Interleaved 16-bit samples for `count` frames of the given channels.
    package static func samples(_ channels: [[Float]], count: Int) -> Data {
        var data = Data(capacity: count * channels.count * 2)
        for frame in 0..<count {
            for channel in channels {
                let sample = frame < channel.count ? channel[frame] : 0
                data.appendLittleEndian(UInt16(bitPattern: Int16(min(max(sample, -1), 1) * Float(Int16.max))))
            }
        }
        return data
    }
}

/// Reads WAV from a stream that cannot seek, such as stdin, as float samples per channel. Accepts 16-bit and 32-bit
/// float PCM, with the data size either exact or unknown (streamed).
package final class WAVStreamReader {
    private enum SampleFormat {
        case int16
        case float32
    }

    package let sampleRate: Double
    package let channelCount: Int
    private let sampleFormat: SampleFormat
    private let handle: FileHandle
    /// Bytes of audio left, or nil for a stream that runs until its end.
    private var remainingBytes: Int?

    package init(handle: FileHandle) throws {
        self.handle = handle
        guard let riff = try Self.read(12, from: handle), riff.ascii(0..<4) == "RIFF", riff.ascii(8..<12) == "WAVE"
        else {
            throw ReaderError("not a WAV stream")
        }
        var format: (sampleFormat: SampleFormat, channelCount: Int, sampleRate: Double)?
        while true {
            guard let chunkHeader = try Self.read(8, from: handle) else { throw ReaderError("WAV stream has no audio") }
            let chunkID = chunkHeader.ascii(0..<4)
            let chunkSize = chunkHeader.littleEndianUInt32(at: 4)
            if chunkID == "data" {
                guard let format else { throw ReaderError("WAV stream has no format") }
                (sampleFormat, channelCount, sampleRate) = format
                let isStreamed = chunkSize == WAVStream.unknownSize || chunkSize == 0
                remainingBytes = isStreamed ? nil : Int(chunkSize)
                return
            }
            guard let body = try Self.read(Int(chunkSize) + Int(chunkSize % 2), from: handle) else {
                throw ReaderError("WAV stream ended in its header")
            }
            if chunkID == "fmt " {
                format = try Self.parseFormat(body)
            }
        }
    }

    /// Up to `maxFrames` frames, one array per channel, or nil at the end of the stream.
    package func read(maxFrames: Int) throws -> [[Float]]? {
        let bytesPerSample = sampleFormat == .int16 ? 2 : 4
        let bytesPerFrame = bytesPerSample * channelCount
        var wanted = maxFrames * bytesPerFrame
        if let remainingBytes { wanted = min(wanted, remainingBytes - remainingBytes % bytesPerFrame) }
        guard wanted > 0, let data = try Self.read(wanted, from: handle) else { return nil }
        remainingBytes = remainingBytes.map { $0 - data.count }
        let frameCount = data.count / bytesPerFrame
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
        data.withUnsafeBytes { bytes in
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let offset = frame * bytesPerFrame + channel * bytesPerSample
                    channels[channel][frame] =
                        switch sampleFormat {
                        case .int16:
                            Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                                / Float(Int16.max)
                        case .float32:
                            Float(
                                bitPattern: UInt32(
                                    littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                                )
                            )
                        }
                }
            }
        }
        return frameCount > 0 ? channels : nil
    }

    private static func parseFormat(_ body: Data) throws -> (SampleFormat, Int, Double) {
        guard body.count >= 16 else { throw ReaderError("WAV format chunk is too short") }
        var formatTag = body.littleEndianUInt16(at: 0)
        let extensible: UInt16 = 0xFFFE
        if formatTag == extensible, body.count >= 26 { formatTag = body.littleEndianUInt16(at: 24) }
        let bitsPerSample = body.littleEndianUInt16(at: 14)
        let sampleFormat: SampleFormat
        switch (formatTag, bitsPerSample) {
        case (1, 16): sampleFormat = .int16
        case (3, 32): sampleFormat = .float32
        default: throw ReaderError("unsupported WAV format \(formatTag) with \(bitsPerSample)-bit samples")
        }
        let channelCount = Int(body.littleEndianUInt16(at: 2))
        guard channelCount > 0 else { throw ReaderError("WAV stream has no channels") }
        return (sampleFormat, channelCount, Double(body.littleEndianUInt32(at: 4)))
    }

    /// Exactly `count` bytes, fewer at the end of the stream, or nil if it already ended.
    private static func read(_ count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data.isEmpty && count > 0 ? nil : data
    }

    package struct ReaderError: LocalizedError {
        package let errorDescription: String?

        package init(_ description: String) {
            errorDescription = description
        }
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate func ascii(_ range: Range<Int>) -> String {
        String(decoding: self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)], as: UTF8.self)
    }

    fileprivate func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndianUInt16(at: offset)) | UInt32(littleEndianUInt16(at: offset + 2)) << 16
    }
}
