# totalrecall

**Meeting recording and transcription that runs entirely on your Mac. Free, with no AI subscription, no account and no
cloud.**

Zoom, Google Meet, Slack huddles, Teams: if your Mac plays it, `totalrecall` records it, along with your microphone.
Pipe it into `transcribe` for a live transcript that knows who's talking. Transcription uses the speech recognizer
built into macOS, so your audio and your words never leave your Mac.

[![totalrecall - | transcribe - --live: a YouTube video's audio is transcribed as "Them", the microphone as "You", and
the mic follows a switch to AirPods mid-recording](docs/demo.jpg)](docs/demo.mp4)

▶ [Watch the demo](docs/demo.mp4) (1½ min, with sound)

## Quick start

```sh
totalrecall standup.mp3                                                 # record, press Ctrl-C to stop and save
transcribe standup.mp3                                                  # transcribe a recording afterwards

totalrecall - | transcribe - --live                                     # live transcript as people speak
totalrecall standup.mp3 --stream | transcribe - standup.txt --live      # live transcript as people speak with artifacts
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
totalrecall ~/Meetings/standup.m4a                                 # mic left, everyone else right
totalrecall --no-speaker-isolation call.m4a                        # ordinary mixed recording
totalrecall --mic macbook call.m4a                                 # keep the Mac mic even with AirPods in
totalrecall --no-mic webinar.m4a                                   # system audio only
totalrecall standup.m4a --stream | transcribe - standup.txt --live # keep the audio, see and save the transcript
totalrecall standup.m4a --stream | transcribe - standup.txt        # the same, without showing the transcript
totalrecall - | ffmpeg -i - meeting.flac                           # stream into any tool that reads WAV
transcribe --language es reunion.mp3                               # Spanish (or es-MX, fr, ja, ...)
```

<details>
<summary>All options</summary>

```sh
totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force] [--stream] <output-file>
totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] -
totalrecall --list-mics
```

| Option | Effect |
| --- | --- |
| `--mic NAME` | Prefer this mic whenever it's connected (part of a `--list-mics` name); otherwise use the system input |
| `--no-mic` | Record system audio only |
| `--no-speaker-isolation` | Mix mic and system audio into both channels instead of left/right |
| `--no-echo-cancellation` | Keep the raw mic signal |
| `--force` | Overwrite an existing output file |
| `--stream` | Also stream WAV to stdout while saving the output file |
| `--list-mics` | List microphones; `*` marks the current system input |
| `-` as output | Only stream WAV to stdout, without saving a file |

```sh
transcribe [--language LANG] [--mix] [--identify-speakers] [--force] <audio-file> [<text-file>]
transcribe [--language LANG] [--mix] [--identify-speakers] [--force] [--live] - [<text-file>]
transcribe speakers [name <number> <name> | merge <number> <into-number> | forget <number>]
transcribe speakers [play <number> | save <number> <directory>]
transcribe --list-languages
```

| Option | Effect |
| --- | --- |
| `--language LANG` | Language spoken, e.g. `es` or `es-MX` (default `en-US`) |
| `--mix` | Transcribe both channels together, without speaker labels |
| `--identify-speakers` | Tell the people on the right channel apart by voice: `Them 1`, `Them 2`, ... (`Speaker 1`, `Speaker 2`, ... on a recording without the split, or with `--mix`). Everyone is saved as they are heard, in `~/.transcribe/speakers.db`, so they keep their number from call to call; your mic is always `You` |
| `speakers` | List the people `--identify-speakers` remembers; `name 3 Ada` names one, `merge 5 3` makes 5 part of 3, `forget 5` takes one out |
| `speakers play 3`, `speakers save 3 <directory>` | Play the samples kept of someone with no name yet, their 4 longest stretches of speech of up to 15 s, to tell who they are; or save them as `.m4a` files |
| `--list-languages` | List supported languages; `*` marks models already downloaded |
| `-` as input | Transcribe a live WAV stream from stdin, such as `totalrecall -` |
| `--live` | With `-`: show the live transcript, words still being recognized included, even with a `<text-file>` |
| `<text-file>` | Write the transcript there instead of printing it, each line as it settles |
| `--force` | Overwrite an existing `<text-file>` |

Both tools also take `--version` and `--help`.

</details>

## Good to know

- **Turn on Do Not Disturb.** totalrecall records *all* system audio, notification sounds included.
- **Recording starts after a short pause.** totalrecall waits until the mic is live and it has heard about a second of
  the room. With AirPods, that takes 2–3 s.
- **Stopping a live transcript.** Ctrl-C stops recording, and `transcribe` writes the last words before it exits. Press
  Ctrl-C again to quit immediately. If you pipe `transcribe` into another program, such as `tee`, make it ignore Ctrl-C
  too (`tee -i`), or it misses those last lines.
- **Lines come out as they settle.** `transcribe` writes each line the moment the recognizer is sure of it. With you and
  the others on separate channels, each has its own recognizer, so a `You` line can come out before an earlier `Them`
  line, from a file more so, as both race through it.
- **`--identify-speakers` goes by voice alone, and is cautious.** It tells voices apart with a speaker-recognition model
  built into `transcribe`, on this Mac, and only takes someone for a new person after a few seconds of a voice unlike
  everyone so far: a quick "yes" from a newcomer goes to whoever they sound most like. A line where two people talk
  goes to whoever spoke longer, which matters most with `--mix`, where the recognizer often runs two people's turns
  into one line. Live, each line waits a few seconds after it is spoken, while the words still being recognized go on
  showing, so a newcomer's first words are theirs too. People keep their number from call to call; name them with
  `transcribe speakers name`. Until someone
  has a name, a few short samples of their speech are kept in `~/.transcribe/speakers.db` too, so you can tell who they
  are with `transcribe speakers play`; `transcribe speakers forget` deletes them along with the person.
- **The stream ending doesn't end the recording.** With `--stream`, if the program reading it exits, `totalrecall` says
  so and keeps recording the file.
- **AirPods sound lower quality.** Their Bluetooth call profile records at about 24 kHz. That's fine for transcripts,
  but the Mac mic is clearer in a quiet room.
- **Headphones beat echo cancellation.** Echo cancellation reduces the "everyone twice" effect a lot, but not
  completely.
- **The first transcription in a language takes longer** while Apple's speech model downloads.
- **Tell people you're recording.** Some places require everyone's consent.

## Credits

`transcribe --identify-speakers` tells voices apart with [WeSpeaker](https://github.com/wenet-e2e/wespeaker)'s
[ResNet34-LM speaker model](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), trained on
[VoxCeleb](https://www.robots.ox.ac.uk/~vgg/data/voxceleb/), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); it is converted to Core ML, unchanged otherwise.
