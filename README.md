# totalrecall

Record any meeting — Zoom, Slack huddles, Google Meet, Teams, anything that plays through your Mac — to an audio file
from the command line. Start it, talk, press Ctrl-C, and the recording is saved where you said.

```sh
totalrecall ~/Meetings/standup.mp3
```

It can also stream the recording into `transcribe`, the on-device speech-to-text tool that ships with it, for a live
transcript that labels who is talking:

```sh
totalrecall - | transcribe -
```

[![totalrecall - | transcribe - live: a YouTube video's audio is transcribed as "Them", the microphone as "You", and the
mic follows a switch to AirPods mid-recording](docs/demo.jpg)](docs/demo.mp4)

▶ [Watch the demo](docs/demo.mp4) (1½ min, with sound): `totalrecall - | transcribe -` transcribing a YouTube video
as Them and the microphone as You, live, and following the switch to AirPods mid-recording.

## Why

Meeting apps either don't let you keep a recording (Slack huddle captions vanish when the huddle ends) or only record
when the host allows it and announce it to everyone. macOS has no built-in way to record "what the speakers are
playing" together with your microphone: QuickTime and Cmd-Shift-5 only capture the mic, and the usual workaround is a
virtual loopback driver such as BlackHole plus a Multi-Output Device, which breaks your volume keys and has to be
reconfigured whenever you switch between AirPods and speakers.

totalrecall uses Core Audio process taps to capture system audio directly, so there is no driver, no audio
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

- macOS 26 or later; the tools refuse to launch on anything older
- [ffmpeg](https://ffmpeg.org/) only for formats macOS can't write natively, such as `.mp3` or `.flac`:
  `brew install ffmpeg`

## Install

Download the latest release (Apple Silicon) and put both tools on your `PATH`:

```sh
gh release download --repo kingbuzzman/totalrecall --pattern '*.tar.gz'
tar -xzf totalrecall-*-macos-arm64.tar.gz -C ~/.local/bin totalrecall transcribe
```

The binaries are not notarized. Downloading with `gh` or `curl` works as is; if you download the tarball with a
browser, clear the quarantine flag first: `xattr -d com.apple.quarantine totalrecall-*.tar.gz`.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
make            # builds ./totalrecall and ./transcribe
make install    # symlinks both into ~/.local/bin (override with PREFIX=/some/dir)
```

The first build downloads and compiles [speexdsp](https://speex.org/) (echo cancellation), which is linked into
totalrecall, so the binary needs nothing installed. Make sure `~/.local/bin` is on your `PATH`.

## Usage

```sh
totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force] <output-file | ->
totalrecall --list-mics
totalrecall --version
```

| Option | Effect |
| --- | --- |
| `--mic NAME` | Prefer this mic whenever it is connected (case-insensitive part of a `--list-mics` name, e.g. `--mic airpods`); falls back to the system input otherwise |
| `--no-mic` | Record system audio only |
| `--no-speaker-isolation` | Mix mic and system audio into both channels instead of left/right |
| `--no-echo-cancellation` | Keep the raw mic signal |
| `--force` | Overwrite an existing output file |
| `--list-mics` | List microphones; `*` marks the current system input |
| `--version` | Print the version (also shown at the top of `--help`) |

The output format follows the extension: `.m4a` (AAC), `.wav`, `.aiff` and `.caf` are written natively; anything
else is converted with ffmpeg. With `-` instead of a file name, the recording streams to stdout as WAV while it is
being made, for another program to read: `transcribe -`, or `ffmpeg -i - meeting.mp3`.

Examples:

```sh
totalrecall /tmp/meeting.mp3                          # mic left, everyone else right
totalrecall --no-speaker-isolation ~/call.m4a         # ordinary mixed recording
totalrecall --mic "macbook" ~/call.m4a                # keep using the Mac mic even with AirPods in
```

Stop with Ctrl-C (SIGTERM and closing the terminal also save the file).

Recording starts once the microphone is actually on and totalrecall has heard a second of the room, so that its noise
suppression starts out tuned to the background; with AirPods that takes 2–3 s. The counter starts at that moment and
the file covers exactly the time it shows.

## Transcription

`transcribe` turns speech into text on-device with Apple's speech recognizer; nothing leaves the Mac.

```sh
transcribe [--language LANG] [--mix] <audio-file | -> [<text-file>]
transcribe --list-languages
```

```sh
totalrecall - | transcribe -                        # live: text appears as people speak
transcribe ~/Meetings/standup.mp3                   # a finished recording, printed in time order
transcribe standup.mp3 standup.txt                  # ... or written to a file
transcribe --language es reunion.mp3                # in Spanish
totalrecall - | transcribe - | tee -i standup.txt   # live on screen and saved to a file as it goes
```

The default language is US English. `--language` takes a language (`es`) or a language and region (`es-MX`); a
language alone uses your Mac's region when the recognizer has it, else the language's main one. `--list-languages`
lists what Apple's recognizer supports, with `*` on the ones already downloaded.

Recordings with totalrecall's channel split are labeled by speaker, since your mic is on the left and everyone else on
the right:

```
[00:00:03] You: Today we will review the release plan.
[00:00:05] Them: Sounds good, the migration finished yesterday.
```

Mixed recordings (`--no-speaker-isolation`, `--no-mic`) and `--mix` give one unlabeled transcript. Live on a terminal,
the words still being recognized show on the last line, and each line is printed about a second after it is spoken.
The first run in each language downloads Apple's speech model for it.

Ctrl-C on a live pipeline stops totalrecall, which ends the stream; `transcribe` finishes the words it has already
heard, prints them, and only then exits (press Ctrl-C again to quit at once). With `tee`, use `-i` so that `tee` keeps
running for those last lines too. Through `tee` the output is not a terminal, so only finished lines are shown, not the
words still being recognized.

## Permissions

totalrecall needs two separate permissions, which macOS grants to the terminal app you run it from:

- **System audio** — System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording
  Only
- **Microphone** — System Settings › Privacy & Security › Microphone (not needed with `--no-mic`)

On start it checks both and asks for any that macOS has not asked about yet. If one is denied, it exits with an error
saying where to allow it; macOS does not ask again once you have said no. After allowing system audio, quit and
reopen the terminal.

Apple offers no public way to check or request the system audio permission (without it, recordings silently get no
system audio), so totalrecall uses macOS's undocumented TCC functions for it; see
`Sources/TotalRecall/Devices/SystemAudioPermission.swift`. If a macOS update removes them, totalrecall records without
the check.

## Code layout

`make` builds two binaries from `Sources/`, plus the code they share:

| Folder | Contents |
| --- | --- |
| `TotalRecall/` | The recorder (layout below) and its `Info.plist` |
| `Transcribe/` | The transcriber: audio sources (file or stdin stream), one recognizer per speaker, and the transcript printer |
| `Shared/` | The WAV stream format between `totalrecall -` and `transcribe -`, and the version |

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

`make coverage` runs the suite against a build of totalrecall instrumented for coverage (it takes `TESTS` like
`make test`), prints line coverage per file, writes an HTML report to `tests/build/coverage/html`, and fails if
coverage drops below `COVERAGE_MIN` percent (set in the `Makefile`). Without the BlackHole devices it runs only
the scenarios that need none and reports that partial coverage without checking the minimum. CI runs it after `make test`, shows the
report in the job summary, and uploads the HTML as the `coverage` artifact. The released binaries are the
uninstrumented ones.

Known limit: totalrecall's system-audio capture also hears the fake mics' playback, so echo cancellation sees the
"voice" in its reference signal. The echo scenario therefore checks only that echo is reduced, not that the voice is
untouched.

## Notes and limitations

- It records **all** system audio, including notification sounds and music. Use Do Not Disturb during meetings.
- With the AirPods mic active, macOS uses the Bluetooth call profile, so your voice is recorded at about 24 kHz. That
  is fine for transcription; the Mac mic is clearer in a quiet room.
- Tell the other participants when you record. Some jurisdictions require everyone's consent.

## Releasing

The version lives in `VERSION`; the build writes it into both tools. To release, add a `## <version>` section to
`CHANGELOG.md`, bump `VERSION` and push to `master`. The integration workflow builds both tools on macOS 26 and tests
them; only if the tests pass does `.github/workflows/release.yml` check that `v<VERSION>` has no tag yet and publish
a GitHub release with the tag, that section as its notes, and the `totalrecall-<VERSION>-macos-arm64.tar.gz` that
integration built. `make release` builds the same tarball locally, in `build/`.
