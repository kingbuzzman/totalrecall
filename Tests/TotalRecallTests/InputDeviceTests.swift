import CoreAudio
import Testing

@testable import TotalRecall

/// These read the Mac's real input devices, which need no permission.
@Suite(.enabled(if: InputDevice.systemInput() != nil, "needs an input device"))
struct InputDeviceTests {
    @Test func listsTheSystemInputAmongTheInputDevices() throws {
        let systemInput = try #require(InputDevice.systemInput())

        #expect(InputDevice.all().contains { $0.id == systemInput.id && $0.name == systemInput.name })
        #expect(defaultInputDevice() == systemInput.id)
    }

    @Test func matchesNamesIgnoringCaseAndCurlyApostrophes() throws {
        let device = try #require(InputDevice.all().first)
        let query = device.name.uppercased().replacingOccurrences(of: "\u{2019}", with: "'")

        #expect(InputDevice.matching(query).contains { $0.id == device.id })
        #expect(InputDevice.matching("no such microphone").isEmpty)
    }

    @Test func readsTheFormatOfTheFirstInputStream() throws {
        let format = try #require(InputDevice.systemInput()).streamFormat()

        #expect(format.mSampleRate > 0)
        #expect(format.mChannelsPerFrame > 0)
    }

    @Test func picksTheSystemInputWhenThePreferredMicIsMissing() throws {
        let systemInput = try #require(InputDevice.systemInput())

        #expect(MicrophoneCapture.systemTarget(preferredName: nil)?.id == systemInput.id)
        #expect(MicrophoneCapture.systemTarget(preferredName: "no such microphone")?.id == systemInput.id)
    }

    @Test func picksThePreferredMicWhenPresent() throws {
        let device = try #require(InputDevice.all().last)

        #expect(MicrophoneCapture.systemTarget(preferredName: device.name)?.id == device.id)
    }
}

struct AudioObjectTests {
    @Test func turnsAFailedCallIntoAnError() {
        #expect(throws: Never.self) { try ensure(noErr, "reading") }
        #expect {
            try ensure(kAudioHardwareBadObjectError, "reading the format")
        } throws: { error in
            error.localizedDescription == "reading the format failed (OSStatus \(kAudioHardwareBadObjectError))"
        }
    }

    @Test func failsToReadADeviceThatDoesNotExist() {
        let ghost = InputDevice(id: 0xDEAD, name: "Ghost Mic")

        #expect {
            try ghost.streamFormat()
        } throws: { error in
            error.localizedDescription.hasPrefix("listing Ghost Mic streams failed")
        }
        #expect(stringProperty(0xDEAD, kAudioObjectPropertyName) == nil)
    }
}
