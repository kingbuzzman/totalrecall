import AudioLab
import Foundation
import Shared
import Testing
import os

@testable import Transcribe

/// How much memory a long live transcript takes, and whether it is given back once it is done, as the app transcribes
/// each recording it makes: a conversation in the system voice, streamed through a pipe into `transcribeLive`, as
/// fast as the recognizer takes it. Slow, so it only runs given `TRANSCRIBE_SOAK_MINUTES`, the minutes of audio:
///
///     TRANSCRIBE_SOAK_MINUTES=60 swift test --filter MemorySoakTests
@Suite(.serialized)  // One at a time: in one process, cases running at once would share each other's memory.
struct MemorySoakTests {
    private static let minutes = ProcessInfo.processInfo.environment["TRANSCRIBE_SOAK_MINUTES"].flatMap(Double.init)
    /// How many times real time the audio comes in, as a recording would at 1: by default 20, below how fast the
    /// recognizer goes, so that, as in a recording, no audio waits for it.
    private static let speed = ProcessInfo.processInfo.environment["TRANSCRIBE_SOAK_SPEED"].flatMap(Double.init) ?? 20
    /// How many meetings in a row, to tell memory kept once, such as a framework's caches, from memory kept per meeting.
    private static let meetings =
        ProcessInfo.processInfo.environment["TRANSCRIBE_SOAK_MEETINGS"].flatMap(Int.init) ?? 3

    @Test(
        .enabled(if: minutes != nil, "set TRANSCRIBE_SOAK_MINUTES to run it"),
        .enabled("needs on-device speech recognition") { await speechRecognitionIsAvailable() },
        arguments: [false, true]
    )
    func givesBackTheMemoryOfALongTranscriptOnceItIsDone(identifiesSpeakers: Bool) async throws {
        let minutes = try #require(Self.minutes)
        // You on the left, them on the right, taking turns, as totalrecall records a call.
        let you = try await SystemVoice.samples(saying: "Good morning everyone, thanks for joining the call today.")
        let them = try await SystemVoice.samples(saying: "Happy to be here, the migration finished yesterday evening.")
        let silence = [Float](repeating: 0, count: 48_000)
        let left = you + silence + [Float](repeating: 0, count: them.count) + silence
        let right = [Float](repeating: 0, count: you.count) + silence + them + silence
        let audio = (left: left, right: right)
        let baseline = Memory.now()
        print(
            String(
                format: "soak, speakers %@: footprint at rest %.0f MB",
                identifiesSpeakers ? "on" : "off",
                baseline.footprint
            )
        )
        for meeting in 1...Self.meetings {
            let peak = try await transcribe(minutes: minutes, of: audio, identifiesSpeakers: identifiesSpeakers)
            try await Task.sleep(for: .seconds(10))
            let after = Memory.now()
            // As the app does once a recording has wholly finished: gives back what it freed.
            let relieved = Memory.afterPressureRelief()
            print(
                String(
                    format: "  meeting %d of %.0f min: peak %.0f MB, 10 s after %.0f MB (in use %.0f MB), "
                        + "given back %.0f MB",
                    meeting,
                    minutes,
                    peak,
                    after.footprint,
                    after.inUse,
                    relieved.footprint
                )
            )
        }
    }

    /// Transcribes `minutes` of the conversation, coming in at `speed` times real time; returns the peak footprint.
    private func transcribe(
        minutes: Double,
        of audio: (left: [Float], right: [Float]),
        identifiesSpeakers: Bool
    ) async throws -> Double {
        let turns = Int((minutes * 60 * 48_000 / Double(audio.left.count)).rounded(.up))
        let turnSeconds = Double(audio.left.count) / 48_000 / Self.speed
        let peak = OSAllocatedUnfairLock(initialState: Memory.now().footprint)
        let pipe = Pipe()
        let text = FileManager.default.temporaryDirectory.appending(path: "soak-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: text) }
        let lines = OSAllocatedUnfairLock(initialState: 0)
        let writer = Task.detached {
            let handle = pipe.fileHandleForWriting
            try handle.write(contentsOf: WAVStream.header(sampleRate: 48_000, channelCount: 2))
            let start = ContinuousClock.now
            for turn in 0..<turns {
                try handle.write(contentsOf: WAVStream.samples([audio.left, audio.right], count: audio.left.count))
                peak.withLock { $0 = max($0, Memory.now().footprint) }
                try await Task.sleep(until: start + .seconds(turnSeconds * Double(turn + 1)))
            }
            try handle.close()
        }
        try await transcribeLive(
            from: pipe.fileHandleForReading,
            to: text,
            language: nil,
            identifiesSpeakers: identifiesSpeakers,
            handlers: LiveTranscriptHandlers(
                onLine: { _ in lines.withLock { $0 += 1 } },
                onLiveText: { _ in },
                onMessage: { _ in }
            )
        )
        try await writer.value
        #expect(lines.withLock { $0 } > 0)
        return peak.withLock { $0 }
    }
}

/// The process's memory: its footprint, what Activity Monitor shows as Memory, and what it has allocated and not
/// freed, in megabytes.
enum Memory {
    static func now() -> (footprint: Double, inUse: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Double(info.phys_footprint) / 1_048_576, Double(stats.size_in_use) / 1_048_576)
    }

    /// After asking malloc to give back the memory it holds freed, as macOS would under memory pressure.
    static func afterPressureRelief() -> (footprint: Double, inUse: Double) {
        malloc_zone_pressure_relief(nil, 0)
        return now()
    }
}
