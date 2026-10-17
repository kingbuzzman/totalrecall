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
  switches the mic automatically. If a capture stops delivering audio it is rebuilt, and the gap is filled with silence
  so the two channels stay in sync.
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

## Notes and limitations

- It records **all** system audio, including notification sounds and music. Use Do Not Disturb during meetings.
- With the AirPods mic active, macOS uses the Bluetooth call profile, so your voice is recorded at about 24 kHz. That
  is fine for transcription; the Mac mic is clearer in a quiet room.
- Tell the other participants when you record. Some jurisdictions require everyone's consent.
