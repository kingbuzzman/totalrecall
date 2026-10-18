import Testing

@testable import AudioLab

/// The player tool behind the fake speakers and microphones, which needs no test devices to fail.
struct PlayerProcessTests {
    /// The player's own failure, so it was found next to the test bundle and started.
    @Test func reportsADeviceThatDoesNotExist() async {
        await #expect {
            try await PlayerProcess(deviceNamed: "no such device", tracks: [ClickTrack(pitch: 1_000)])
        } throws: { error in
            "\(error)" == "the player for no such device failed with status 1"
        }
    }
}
