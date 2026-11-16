# Developing totalrecall

## Build from source

Needs macOS 26 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make              # builds build/bin/totalrecall and build/bin/transcribe
make install      # copies both into ~/.local/bin (override with PREFIX=/some/dir)
make build-app    # builds build/TotalRecall.app, the menu bar app; needs Xcode, for actool
make install-app  # copies it into ~/Applications (override with APP_DIR=/some/dir)
make build        # builds everything: both tools and the app
```

`make lint` runs two linters, which split the work: **swift-format** owns the layout (`make format` rewrites the code
to it, as configured in `.swift-format`), and **SwiftLint** checks what it does not: complexity and length, likely bugs,
and Swift that has a clearer or faster idiom, as configured in `.swiftlint.yml`, which turns its layout rules off
(`Tests/.swiftlint.yml` raises only the length limits, for test suites). SwiftLint is downloaded into `build/` the
first time, its release binary pinned by version and checksum. Speaker identification is let off its size rules,
declaration by declaration, until it is cleaned up (see `TODO.md`).

`make build-app` compiles the app's icons, `Resources/AppIcon.icon` (made with Icon Composer) and the menu bar icons
in `Resources/Assets.xcassets`, with `actool`, which comes with Xcode, not the Command Line Tools. The app is signed
like the tools, as `local.totalrecall.app`, so macOS keeps its permissions across rebuilds.

The tools are a Swift package (`Package.swift`) built through `make`, which first downloads and compiles
[speexdsp](https://speex.org/) (echo cancellation) for the package to link into totalrecall, so the binary needs nothing
installed, and embeds each tool's `Info.plist` with the version from `VERSION` as `<VERSION>-devYYYYMMDD.HHMMSS`, the
local time of the build; a CI build reports `<VERSION>-dev<commit>`, and only a release build (`make FINAL=1`) reports
`VERSION` as is. Make sure `~/.local/bin` is on your `PATH`. Everything a build makes goes in `build/`, which `make
clean` deletes.

`make` also builds the speaker models `transcribe --identify-speakers` uses into `transcribe`: each Core ML package's
model and weights, a section of its binary each, which Core ML loads from memory, so the tool is still a single file and
writes nothing to disk. `Models/SpeakerEmbedding.mlpackage` is WeSpeaker's ResNet34-LM (CC BY 4.0), which tells voices
apart, converted from its ONNX export by `scripts/convert-speaker-model.py`; `Models/SpeakerSegmentation.mlpackage` is
pyannote's segmentation-3.0 (MIT), which finds who talks when, rebuilt from its ONNX export's weights by
`scripts/convert-segmentation-model.py`. Both scripts check the conversion against the original; only rerun one to
change its model (`uv run scripts/convert-speaker-model.py`). `transcribe`'s unit tests load the packages from
`Models/` instead.

`make` signs both tools with the code-signing certificate `TotalRecall Local` from your keychain, so macOS keeps their
microphone and speech permissions across rebuilds. Create it once in Keychain Access: Certificate Assistant → Create a
Certificate, named `TotalRecall Local`, Identity Type Self-Signed Root, Certificate Type Code Signing. Use another
certificate with `CODESIGN_IDENTITY="Apple Development: …"`, or none with `CODESIGN_IDENTITY=`; CI builds are not
signed.

## How it works

`totalrecall` uses Core Audio process taps to capture system audio directly, so there is no driver, no audio
rerouting, and nothing to reconfigure.

- **Channels.** Your mic goes on the left channel, system audio on the right. `--no-speaker-isolation` mixes both into
  both channels instead.
- **Echo cancellation.** Without headphones the mic also hears the other participants through the speakers. Because
  totalrecall has the exact system audio, it uses it as the reference for a speexdsp acoustic echo canceller and strips
  that audio back out of your mic channel. In testing on MacBook Pro speakers this lowered the echo by ~13–15 dB; it
  reduces the "everyone twice" effect a lot but does not remove it completely.
- **Device switching.** The mic tracks the macOS system input. Switching is make-before-break: the old mic keeps
  recording until the new one delivers real audio, which hides the ~2 s AirPods need to switch Bluetooth into their
  call profile. If a capture stops delivering audio it is rebuilt, and any gap is filled with silence so the two
  channels stay in sync.
- **Crash safety and quick saving.** While recording it writes raw audio to `<output>.partial.caf`, which a crash
  leaves readable. At the same time `LiveEncoder` converts the audio into the requested format, into
  `<name>.encoding.<ext>`, on a queue of its own, with AVFoundation or, for `.mp3`, an ffmpeg fed on its stdin. So on
  Ctrl-C saving only finishes that file and renames it. If converting fails, or falls more than 2 minutes behind,
  the partial recording is converted instead, as before. `.caf` needs no conversion.
- **Start of recording.** Recording starts once the microphone is actually on and totalrecall has heard a second of the
  room, so that its noise suppression starts out tuned to the background. The counter starts at that moment and the
  file covers exactly the time it shows.
- **System audio permission.** Apple offers no public way to check or request it (without it, recordings silently get
  no system audio), so `totalrecall` uses macOS's undocumented TCC functions for it; see
  `Sources/TotalRecall/Devices/SystemAudioPermission.swift`. If a macOS update removes them, `totalrecall` records
  without the check.

## Code layout

`make` builds two binaries from `Sources/`, plus the code they share. The recorder and the transcriber are libraries,
each with a small command-line target on top, so the menu bar app runs both in its own process:

| Folder | Contents |
| --- | --- |
| `TotalRecall/` | The recorder library (layout below), and `totalrecall`'s `Info.plist` |
| `TotalRecallCommand/` | `totalrecall`'s entry point, and the only code that exits: parses options, checks the output and permissions, starts the session, saves on a stop signal |
| `Transcribe/` | The transcriber library: `CommandLine/` (arguments and the tool), `Transcription/` (what the tool and the app share: audio sources, one recognizer per speaker, the echo filter, the transcript printer), and `Speakers/` (telling people apart by voice, and the database of those remembered) |
| `TranscribeCommand/` | `transcribe`'s entry point |
| `TotalRecallApp/` | The menu bar app: `Model/` (`AppModel`, notifications, today's meetings from Calendar.app through EventKit, and `RecordingEngine`, which records and transcribes as `record-meetings` pipes the tools, but streaming through a pipe in the same process), `Menu/`, `Transcript/`, `Settings/` and `Windows/` |
| `AppSupport/` | What the app decides without a user interface, so it can be tested, as `record-meetings` decides it: which events are meetings, which to record next and when to warn of them (`MeetingSchedule`), the folders recordings go in, and the formats it offers |
| `Shared/` | The WAV stream format between `totalrecall` and `transcribe -`, the input both tools feed their audio converters through, the error type, stop signals, and the version |
| `CSpeexDSP/` | The module map through which `totalrecall` uses speexdsp |

Inside `TotalRecall/`, each folder is a layer that only uses the ones below it:

| Folder | Contents |
| --- | --- |
| `App/` | Command-line options, the recording session (startup, writer timer, saving), stop signals, status output |
| `Capture/` | System-audio tap, microphone capture with make-before-break switching, and the supervisor that restarts stalled captures |
| `Recording/` | Per-channel timelines, echo cancellation, the file or stream it writes to, the live encoder, and export to the final format |
| `Devices/` | Core Audio property helpers, input-device discovery, the microphone and system audio permissions |

`TOTALRECALL_RAW=1` also saves the unprocessed mic and system audio as `<output>.raw.caf`, for tuning the processing
against real recordings.

Files are named the Swift way: after the main type they declare (`StatusLine.swift`), `Type+Topic.swift` for an
extension (`AppModel+Notifications.swift`, `Date+ShortTime.swift`), or after their topic for free functions
(`StopSignals.swift`). The larger targets group files by feature in folders; the small ones stay flat.

`totalrecall`, `transcribe` and the app log to one place: `log show --predicate 'subsystem == "local.totalrecall"'
--last 1d` shows their failures, which macOS keeps; `log stream` with `--info` shows everything as it happens.

Code below `main.swift` reports failures by throwing. Formatting follows `.swift-format`: run `make format` to apply it
and `make lint` to check it. `make lint` also checks the GitHub workflows for security problems with
[zizmor](https://docs.zizmor.sh), run through `pipx` (`brew install pipx`) at the version the Makefile pins.

## Testing

```sh
make test                          # everything; the recording tests need the devices below
make test TESTS=RecorderTests      # a subset (a swift test --filter)
LONG=1 make test                   # adds a 2-minute drift test
make coverage                      # the same tests on a build instrumented for coverage
```

The tests use [Swift Testing](https://developer.apple.com/documentation/testing) and live in `Tests/`:

| Target | Tests |
| --- | --- |
| `TotalRecallTests` | totalrecall's logic: options, the timeline and recorder (alignment, splicing, padding, mixing, the end at the stop), echo cancellation, output files and formats, resampling, sample-rate watching, make-before-break mic switching and capture restarts (with fake sessions), the status line, stop signals, input-device lookup |
| `TranscribeTests` | transcribe's logic: arguments, speaker detection, mixing, the transcript and its live line, language picking, audio sources |
| `SharedTests` | The WAV stream writer and reader, including malformed streams |
| `AudioLabTests` | The click-track analysis the end-to-end tests rely on, and the player tool's failures |
| `IntegrationTests` | The release binaries end to end: totalrecall's command line, transcribe on speech from `say`, and totalrecall recording through fake audio devices |

The recording tests need no microphone or speakers, only three BlackHole loopback devices, so they run the same way
locally and on headless CI machines:

```sh
brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch
```

Without them those tests are skipped, except on CI, where they fail. `Tests/AudioLab` creates fake microphones, each a
temporary aggregate device wrapping a BlackHole device that the tests play a click track into. Every click track, the
speakers' included, plays from a process of its own (`Tests/AudioLabPlayer`): totalrecall's system-audio tap, which
records what every process plays, lost the speakers' clicks when they all played from the test process. Fake mics can
appear, disappear, become the system input, change sample rate, or stay silent for a while before delivering audio,
which is how AirPods look to totalrecall. Every click track is locked to the system clock, so the analysis can find
every click in a recording and report lost audio, silence, which mic was recorded when, and drift between the channels,
in milliseconds. The tests cover recording, switching to a new or slow-starting input, sample-rate changes, a preferred
`--mic` disappearing and returning, rapid switching, echo cancellation, every stop signal, hard kills, every output
format, mixed channels, system audio only, and streaming to stdout. Each test switches the system input and output to
the test devices and restores them afterwards. Recordings and logs are kept in `build/test-results`.

`make coverage` builds the tools and the tests once with coverage instrumentation, runs the tests with the end-to-end
ones on those builds, prints line coverage per file, writes an HTML report to `build/coverage/html`, and fails if
coverage drops below `COVERAGE_MIN` percent (75, set in the `Makefile`). Without the test devices the coverage is partial,
and the minimum is not checked.

CI (`.github/workflows/integration.yml`) runs `make test` and `make coverage` on GitHub's macOS runners, shows the
coverage in the job summary, and uploads the HTML report and the recordings. There,
`.github/scripts/grant-audio-permissions.sh` grants the microphone and system-audio permissions nobody can click
"Allow" for; it refuses to run outside CI. The released binaries are the uninstrumented ones `make test` tested.

Known limit: totalrecall's system-audio capture also hears the fake mics' playback, so echo cancellation sees the
"voice" in its reference signal. The echo test therefore checks only that echo is reduced, not that the voice is
untouched.

## Releasing

The version lives in `VERSION`; the build writes it into both tools. To release, add a `## <version>` section to
`CHANGELOG.md`, bump `VERSION` and push to `master`. The integration workflow builds both tools on macOS 26 and tests
them, as the final version (`FINAL=1`) only on a push to `master` whose `VERSION` has no tag yet, and as
`<VERSION>-dev<commit>` everywhere else; only if the tests pass does `.github/workflows/release.yml` check that
`v<VERSION>` has no tag yet and publish a GitHub release with the tag, that section as its notes, and the
`totalrecall-<VERSION>-macos-arm64.tar.gz` that integration built, after checking that both tools in it are the final
version. `make release FINAL=1` builds the same tarball locally, in `build/`.
