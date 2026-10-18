import Foundation

/// Builds WAV streams byte by byte, including malformed ones.
enum WAVBytes {
    static func riff(_ chunks: Data...) -> Data {
        var data = Data("RIFF".utf8)
        data.append(littleEndian: UInt32.max)
        data.append(contentsOf: "WAVE".utf8)
        chunks.forEach { data.append($0) }
        return data
    }

    static func chunk(_ id: String, _ body: Data) -> Data {
        var data = Data(id.utf8)
        data.append(littleEndian: UInt32(body.count))
        data.append(body)
        if body.count % 2 == 1 { data.append(0) }
        return data
    }

    static func format(tag: UInt16 = 1, channels: UInt16 = 2, sampleRate: UInt32 = 48_000, bits: UInt16 = 16) -> Data {
        let blockAlign = channels * bits / 8
        var body = Data()
        body.append(littleEndian: tag)
        body.append(littleEndian: channels)
        body.append(littleEndian: sampleRate)
        body.append(littleEndian: sampleRate * UInt32(blockAlign))
        body.append(littleEndian: blockAlign)
        body.append(littleEndian: bits)
        return chunk("fmt ", body)
    }

    static func extensibleFormat(subformat: UInt16, channels: UInt16 = 2, bits: UInt16 = 32) -> Data {
        var body = format(tag: 0xFFFE, channels: channels, bits: bits).dropFirst(8)
        body.append(littleEndian: UInt16(22))
        body.append(littleEndian: bits)
        body.append(littleEndian: UInt32(0b11))
        body.append(littleEndian: subformat)
        body.append(Data(count: 14))
        return chunk("fmt ", Data(body))
    }

    static func data(_ body: Data, size: UInt32? = nil) -> Data {
        var data = Data("data".utf8)
        data.append(littleEndian: size ?? UInt32(body.count))
        data.append(body)
        return data
    }

    static func int16Samples(_ samples: [Int16]) -> Data {
        var data = Data()
        samples.forEach { data.append(littleEndian: $0) }
        return data
    }

    static func float32Samples(_ samples: [Float]) -> Data {
        var data = Data()
        samples.forEach { data.append(littleEndian: $0.bitPattern) }
        return data
    }
}

extension Data {
    mutating func append<Value: FixedWidthInteger>(littleEndian value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func ascii(_ range: Range<Int>) -> String {
        String(decoding: self[range], as: UTF8.self)
    }

    func uint16(at offset: Int) -> UInt16 {
        self[offset..<offset + 2].withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    func uint32(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    var int16Samples: [Int16] {
        stride(from: 0, to: count, by: 2).map { Int16(bitPattern: uint16(at: $0)) }
    }
}
