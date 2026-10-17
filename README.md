# totalrecall

**Meeting recording and transcription that runs entirely on your Mac. Free, with no AI subscription, no account and no
cloud.**

Zoom, Google Meet, Slack huddles, Teams: if your Mac plays it, `totalrecall` records it, along with your microphone.
Pipe it into `transcribe` for a live transcript that knows who's talking. Transcription uses the speech recognizer
built into macOS, so your audio and your words never leave your Mac.

[![totalrecall - | transcribe - live: a YouTube video's audio is transcribed as "Them", the microphone as "You", and the
mic follows a switch to AirPods mid-recording](docs/demo.jpg)](docs/demo.mp4)

▶ [Watch the demo](docs/demo.mp4) (1½ min, with sound)

## Quick start

```sh
totalrecall standup.mp3          # record, press Ctrl-C to stop and save
totalrecall - | transcribe -     # live transcript as people speak
transcribe standup.mp3           # transcribe a recording afterwards
```

```
[00:00:03] You: Today we will review the release plan.
[00:00:05] Them: Sounds good, the migration finished yesterday.
```

## Why

AI note-takers charge a monthly fee, upload your meetings to their servers, and often send a bot into the call that
everyone can see. Meeting apps aren't much help on their own: Slack huddle captions vanish when the huddle ends, and Zoom
only records if the host allows it.

totalrecall does the same job with only your Mac:

- 🔒 **100% local.** Recording and transcription run on your Mac. No audio or text is uploaded, and no bot joins the
  call.
- 💸 **Free.** There's no subscription, account, API key or usage limit. It uses the speech recognizer that comes with
  macOS.
- 📴 **Works offline.** After a one-time download of Apple's speech model for each language, it needs no internet.
- 🎧 **No drivers, no setup.** It captures system audio directly with Core Audio, so there's no BlackHole and no audio
  rerouting.
- 🗣️ **You vs. Them.** Your mic goes on the left channel and everyone else on the right, so transcripts are labeled
  by speaker.
- 🔄 **Handles real meetings.** It cancels speaker echo, follows your AirPods in and out mid-call, and survives crashes.

## Install

Needs macOS 26+ on Apple Silicon.

```sh
gh release download --repo kingbuzzman/totalrecall --pattern '*.tar.gz'
tar -xzf totalrecall-*-macos-arm64.tar.gz -C ~/.local/bin totalrecall transcribe
```

- If you downloaded the tarball in a browser, run `xattr -d com.apple.quarantine totalrecall-*.tar.gz` first (the
  binaries aren't notarized).
- For `.mp3` or `.flac` output, run `brew install ffmpeg`. `.m4a`, `.wav`, `.aiff` and `.caf` work without it.
- To build from source, run `make && make install`. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

On the first run, macOS asks your terminal for two permissions: **Microphone** and **System Audio Recording**. After you
allow system audio, quit and reopen the terminal. If you clicked "Don't Allow", turn them on in System Settings ›
Privacy & Security.

## Recipes

```sh
totalrecall ~/Meetings/standup.m4a                  # mic left, everyone else right
totalrecall --no-speaker-isolation call.m4a         # ordinary mixed recording
totalrecall --mic macbook call.m4a                  # keep the Mac mic even with AirPods in
totalrecall --no-mic webinar.m4a                    # system audio only
totalrecall - | transcribe - | tee -i standup.txt   # live transcript, saved as it goes
totalrecall - | ffmpeg -i - meeting.flac            # stream into any tool that reads WAV
transcribe --language es reunion.mp3                # Spanish (or es-MX, fr, ja, ...)
```

<details>
<summary>All options</summary>

```sh
totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force] <output-file | ->
totalrecall --list-mics
```

| Option | Effect |
| --- | --- |
| `--mic NAME` | Prefer this mic whenever it's connected (part of a `--list-mics` name); otherwise use the system input |
| `--no-mic` | Record system audio only |
| `--no-speaker-isolation` | Mix mic and system audio into both channels instead of left/right |
| `--no-echo-cancellation` | Keep the raw mic signal |
| `--force` | Overwrite an existing output file |
| `--list-mics` | List microphones; `*` marks the current system input |
| `-` as output | Stream WAV to stdout while recording |

```sh
transcribe [--language LANG] [--mix] <audio-file | -> [<text-file>]
transcribe --list-languages
```

| Option | Effect |
| --- | --- |
| `--language LANG` | Language spoken, e.g. `es` or `es-MX` (default `en-US`) |
| `--mix` | Transcribe both channels together, without speaker labels |
| `--list-languages` | List supported languages; `*` marks models already downloaded |
| `<text-file>` | Write the transcript there instead of printing it |

Both tools also take `--version` and `--help`.

</details>

## Good to know

- **Turn on Do Not Disturb.** totalrecall records *all* system audio, notification sounds included.
- **Recording starts after a short pause.** totalrecall waits until the mic is live and it has heard about a second of
  the room. With AirPods, that takes 2–3 s.
- **Stopping a live transcript.** Ctrl-C stops recording, and `transcribe` prints the last words before it exits. Press
  Ctrl-C again to quit immediately. With `tee`, use `-i` so those last lines are saved too.
- **AirPods sound lower quality.** Their Bluetooth call profile records at about 24 kHz. That's fine for transcripts,
  but the Mac mic is clearer in a quiet room.
- **Headphones beat echo cancellation.** Echo cancellation reduces the "everyone twice" effect a lot, but not
  completely.
- **The first transcription in a language takes longer** while Apple's speech model downloads.
- **Tell people you're recording.** Some places require everyone's consent.
