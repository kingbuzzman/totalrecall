# Developing totalrecall

## Build from source

Needs macOS 26 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make            # builds build/bin/totalrecall and build/bin/transcribe
make install    # symlinks both into ~/.local/bin (override with PREFIX=/some/dir)
```

The tools are a Swift package (`Package.swift`) built through `make`, which first downloads and compiles
[speexdsp](https://speex.org/) (echo cancellation) for the package to link into totalrecall, so the binary needs
nothing installed, and embeds each tool's `Info.plist` with the version from `VERSION`. Make sure `~/.local/bin` is on
your `PATH`. Everything a build makes goes in `build/`, which `make clean` deletes.

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
- **Crash safety.** While recording it writes raw audio to `<output>.partial.caf`; on Ctrl-C it converts that to the
  requested format and deletes it.
- **Start of recording.** Recording starts once the microphone is actually on and totalrecall has heard a second of the
  room, so that its noise suppression starts out tuned to the background. The counter starts at that moment and the
  file covers exactly the time it shows.
- **System audio permission.** Apple offers no public way to check or request it (without it, recordings silently get
  no system audio), so `totalrecall` uses macOS's undocumented TCC functions for it; see
  `Sources/TotalRecall/Devices/SystemAudioPermission.swift`. If a macOS update removes them, `totalrecall` records
  without the check.

## Code layout

`make` builds two binaries from `Sources/`, plus the code they share:

| Folder | Contents |
| --- | --- |
| `TotalRecall/` | The recorder (layout below) and its `Info.plist` |
| `Transcribe/` | The transcriber: arguments, audio sources (file or stdin stream), speaker detection, one recognizer per speaker, and the transcript printer |
| `Shared/` | The WAV stream format between `totalrecall` and `transcribe -`, the input both tools feed their audio converters through, and the version |
| `CSpeexDSP/` | The module map through which `totalrecall` uses speexdsp |

Inside `TotalRecall/`, each folder is a layer that only uses the ones below it:

| Folder | Contents |
| --- | --- |
| `main.swift` | Entry point and the only code that exits: parses options, checks the output and permissions, starts the session, saves on a stop signal |
| `App/` | Command-line options, the recording session (startup, writer timer, saving), stop signals, status output |
| `Capture/` | System-audio tap, microphone capture with make-before-break switching, and the supervisor that restarts stalled captures |
| `Recording/` | Per-channel timelines, echo cancellation, the file or stream it writes to, and export to the final format |
| `Devices/` | Core Audio property helpers, input-device discovery, microphone permission |
| `Common.swift` | The shared error type and clock |

`TOTALRECALL_RAW=1` also saves the unprocessed mic and system audio as `<output>.raw.caf`, for tuning the processing
against real recordings.

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
| `AudioLabTests` | The click-track analysis the end-to-end tests rely on |
| `IntegrationTests` | The release binaries end to end: totalrecall's command line, transcribe on speech from `say`, and totalrecall recording through fake audio devices |

The recording tests need no microphone or speakers, only three BlackHole loopback devices, so they run the same way
locally and on headless CI machines:

```sh
brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch
```

Without them those tests are skipped, except on CI, where they fail. `Tests/AudioLab` creates fake microphones, each
a temporary aggregate device wrapping a BlackHole device that the tests play a click track into. Fake mics can appear,
disappear, become the system input, change sample rate, or stay silent for a while before delivering audio, which is
how AirPods look to totalrecall. Every click track is locked to the system clock, so the analysis can find every click
in a recording and report lost audio, silence, which mic was recorded when, and drift between the channels, in
milliseconds. The tests cover recording, switching to a new or slow-starting input, sample-rate changes, a preferred
`--mic` disappearing and returning, rapid switching, echo cancellation, every stop signal, hard kills, every output
format, mixed channels, system audio only, and streaming to stdout. Each test switches the system input and output
to the test devices and restores them afterwards. Recordings and logs are kept in `build/test-results`.

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
them; only if the tests pass does `.github/workflows/release.yml` check that `v<VERSION>` has no tag yet and publish
a GitHub release with the tag, that section as its notes, and the `totalrecall-<VERSION>-macos-arm64.tar.gz` that
integration built. `make release` builds the same tarball locally, in `build/`.
