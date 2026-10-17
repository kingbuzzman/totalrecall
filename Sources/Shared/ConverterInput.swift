package import AVFAudio
package import Foundation

/// Feeds `AVAudioConverter` one buffer per conversion. Newer SDKs declare the converter's input block `@Sendable`, so it
/// cannot capture the buffer or a "consumed" flag; it captures this instead. The converter calls the block only from
/// inside `convert`, on the calling thread, so nothing here is ever touched by two threads at once. Reuse one per
/// converter, from one thread at a time.
package final class ConverterInput: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?

    package init() {}

    /// Converts `buffer` into `output` with `converter`; returns the converter's error, if any.
    package func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        into output: AVAudioPCMBuffer
    ) -> NSError? {
        pending = buffer
        defer { pending = nil }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = self.pending else {
                status.pointee = .noDataNow
                return nil
            }
            self.pending = nil
            status.pointee = .haveData
            return next
        }
        return error
    }
}
