# totalrecall

Record any meeting — Zoom, Slack huddles, Google Meet, Teams, anything that plays through your Mac — to an audio file
from the command line. Start it, talk, press Ctrl-C, and the recording is saved where you said.

```sh
totalrecall ~/Meetings/standup.mp3
```

## Why

Meeting apps either don't let you keep a recording (Slack huddle captions vanish when the huddle ends) or only record
when the host allows it and announce it to everyone. macOS has no built-in way to record "what the speakers are
playing" together with your microphone: QuickTime and Cmd-Shift-5 only capture the mic, and the usual workaround is a
virtual loopback driver such as BlackHole plus a Multi-Output Device, which breaks your volume keys and has to be
reconfigured whenever you switch between AirPods and speakers.

totalrecall uses Core Audio process taps (macOS 14.2+) to capture system audio directly, so there is no driver, no audio
rerouting, and nothing to reconfigure. It is app-agnostic: it records everything the Mac plays.

## What it does

- **Records system audio + your microphone** into one stereo file: your mic on the **left** channel, everyone else
  (system audio) on the **right**, so you can always tell when you were talking. `--no-speaker-isolation` mixes both
  into both channels instead.
- **Cancels speaker echo.** Without headphones the mic also hears the other participants through the speakers. Because
  totalrecall has the exact system audio, it uses it as the reference for a speexdsp acoustic echo canceller and strips
  that audio back out of your mic channel. In testing on MacBook Pro speakers this lowered the echo by ~13–15 dB; it
  reduces the "everyone twice" effect a lot but does not remove it completely. Headphones/AirPods avoid it entirely.
- **Follows your devices.** The mic tracks the macOS system input, so putting in or taking out AirPods mid-meeting
  switches the mic automatically. Switching is make-before-break: the old mic keeps recording until the new one
  delivers real audio, which hides the ~2 s AirPods need to switch Bluetooth into their call profile. If a capture
  stops delivering audio it is rebuilt, and any gap is filled with silence so the two channels stay in sync.
- **Survives crashes.** While recording it writes raw audio to `<output>.partial.caf`; on Ctrl-C it converts that to
  the requested format and deletes it. If the process is killed or the Mac crashes, the `.partial.caf` is still
  playable.
- **Shows live levels** for the mic and system audio, and warns if no system audio arrives (usually a missing
  permission).

## Requirements

- macOS 14.2 or later (Apple Silicon or Intel), Xcode Command Line Tools (`xcode-select --install`)
- [speexdsp](https://speex.org/) for echo cancellation: `brew install speexdsp`
- [ffmpeg](https://ffmpeg.org/) only for formats macOS can't write natively, such as `.mp3` or `.flac`:
  `brew install ffmpeg`

## Build and install

```sh
make            # builds ./totalrecall
make install    # symlinks it into ~/.local/bin (override with PREFIX=/some/dir)
```

Make sure `~/.local/bin` is on your `PATH`.

## Usage

```sh
totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force] <output-file>
totalrecall --list-mics
```

| Option | Effect |
| --- | --- |
| `--mic NAME` | Prefer this mic whenever it is connected (case-insensitive part of a `--list-mics` name, e.g. `--mic airpods`); falls back to the system input otherwise |
| `--no-mic` | Record system audio only |
| `--no-speaker-isolation` | Mix mic and system audio into both channels instead of left/right |
| `--no-echo-cancellation` | Keep the raw mic signal |
| `--force` | Overwrite an existing output file |
| `--list-mics` | List microphones; `*` marks the current system input |

The output format follows the extension: `.m4a` (AAC), `.wav`, `.aiff` and `.caf` are written natively; anything
else is converted with ffmpeg.

Examples:

```sh
totalrecall /tmp/meeting.mp3                          # mic left, everyone else right
totalrecall --no-speaker-isolation ~/call.m4a         # ordinary mixed recording
totalrecall --mic "macbook" ~/call.m4a                # keep using the Mac mic even with AirPods in
```

Stop with Ctrl-C (SIGTERM and closing the terminal also save the file).

## Permissions

The first run asks for two permissions for the terminal app you run it from:

- **Microphone** — System Settings › Privacy & Security › Microphone
- **System audio** — System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording
  Only)

If the system meter stays flat while audio is playing, the second one is missing; enable it and restart totalrecall.

## Code layout

`Sources/` is one Swift module built by `make`; each folder is a layer that only uses the ones below it:

| Folder | Contents |
| --- | --- |
| `main.swift` | Entry point and the only code that exits: parses options, checks the output path and permissions, starts the session, saves on a stop signal |
| `App/` | Command-line options, the recording session (writer timer, saving), stop signals, status output |
| `Capture/` | System-audio tap, microphone capture with make-before-break switching, and the supervisor that restarts stalled captures |
| `Recording/` | Per-channel timelines, echo cancellation, the crash-safe partial file, and export to the final format |
| `Devices/` | Core Audio property helpers, input-device discovery, microphone permission |
| `Common.swift` | The shared error type and clock |

Code below `main.swift` reports failures by throwing. Formatting follows `.swift-format`: run `make format` to apply it
and `make lint` to check it.

## Testing

The integration tests run the real `totalrecall` binary and check the files it saves, so they test behavior rather
than implementation and keep working across rewrites. They need no microphone or speakers, only three BlackHole
loopback devices, so they run the same way locally and on headless CI machines:

```sh
brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch   # test devices, once
make test                                                         # all scenarios, ~2 minutes
make test TESTS="switches_to_slow_starting_input"                 # selected scenarios
LONG=1 make test                                                  # adds a 2-minute drift test
```

How it works: `tests/audiolab` creates fake microphones, each a temporary aggregate device wrapping a BlackHole
device that a helper process plays a click track into. Fake mics can appear, disappear, become the system input,
change sample rate, or stay silent for a while before delivering audio, which is how AirPods look to totalrecall.
Every click track is locked to the system clock, so the analysis can find every click in a recording and report lost
audio, silence, which mic was recorded when, and drift between the channels, in milliseconds.

The scenarios (`tests/run.sh`) cover recording, switching to a new or slow-starting input, sample-rate changes, a
preferred `--mic` disappearing and returning, rapid switching, echo cancellation, every stop signal, hard kills,
every output format, mixed channels, and usage errors. While the tests run, the system input and output are
switched to the test devices and restored afterwards. Recordings and logs are kept in `tests/build/results`.

CI runs the same suite on GitHub's macOS runners (`.github/workflows/integration.yml`). There,
`tests/ci/grant-audio-permissions.sh` grants the microphone and system-audio permissions nobody can click "Allow"
for; it refuses to run outside CI.

Known limit: totalrecall's system-audio capture also hears the fake mics' playback, so echo cancellation sees the
"voice" in its reference signal. The echo scenario therefore checks only that echo is reduced, not that the voice is
untouched.

## Notes and limitations

- It records **all** system audio, including notification sounds and music. Use Do Not Disturb during meetings.
- With the AirPods mic active, macOS uses the Bluetooth call profile, so your voice is recorded at about 24 kHz. That
  is fine for transcription; the Mac mic is clearer in a quiet room.
- Tell the other participants when you record. Some jurisdictions require everyone's consent.
