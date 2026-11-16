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
- For `.mp3` output, run `brew install ffmpeg`. `.m4a`, `.flac`, `.wav`, `.aiff` and `.caf` work without it.
- To build from source, run `make && make install`. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- For the menu bar app, download `TotalRecall-*-macos-arm64.zip` from the same release
  (`gh release download --repo kingbuzzman/totalrecall --pattern '*.zip'`), unzip it, and move `TotalRecall.app` to
  Applications. It isn't notarized either: run `xattr -dr com.apple.quarantine TotalRecall.app` first, or open it once
  with right-click › Open. Each release is signed afresh, so after updating, macOS asks for its permissions again. See
  [Menu bar app](#menu-bar-app).

On the first run, macOS asks your terminal for two permissions: **Microphone** and **System Audio Recording**. After you
allow system audio, quit and reopen the terminal. If you clicked "Don't Allow", turn them on in System Settings ›
Privacy & Security.

## Menu bar app

`TotalRecall.app` does what `scripts/record-meetings` does, from the menu bar instead of a terminal: it records your
mic and system audio, transcribes them as they're recorded, and saves both. It runs the recorder and the transcriber
itself, so it doesn't need the command-line tools, and it reads your calendar straight from Calendar.app, so it doesn't
need icalbuddy.

- **Today's meetings.** A few minutes before each meeting a notification says "Standup in 5 minutes", with a soft
  chime, and when it starts, recording starts, if nothing else is being recorded. A recording never stops on its own:
  only when you stop it. Then the app waits for the next meeting, or records right away the one already underway.
  All-day events are left out, and by default so are focus time and prep blocks, as `record-meetings` leaves them
  out. Each calendar can be turned on or off, and set to ignore meetings whose title contains a word or phrase, such
  as "1:1", or matches a regular expression between slashes, such as `/^1:1/`; **Test** shows which of the
  calendar's meetings, from two weeks back to two weeks ahead, a rule would ignore. **Always Ignore Meetings Like
  This**, on a meeting in **Today**, adds its title to its calendar's.
- **Next: Standup at 10:00** shows in the menu. **Today** lists every meeting of the day, to record one now, as when it
  starts early, or skip it.
- **Start Recording** starts right away. **New Meeting…** asks for a name first. Both file the recording under the
  default meeting calendar, set in Settings; hold ⌘ with the menu open for **Start Recording On…** and **New Meeting
  On…**, which ask which calendar, to pick another for one recording. **New Meeting…** suggests the last name given,
  and puts the meeting on that calendar, from when it starts until it's stopped; Start Recording only records. New
  Meeting… is there while a calendar is turned on, and the ⌘ items while there are two or more to pick from.
  **Stop Recording** stops at once, and the next recording can start straight after. The file is saved and the last words written in the background.
- **Continue "…"** records the last meeting again, into its folder, as `rec-2` and `transcript-2`.
- **Show Transcript**, while recording, opens a window with the transcript as it's written, as a table of time, speaker
  and words, your lines in blue and everyone else's in orange, and the words still being recognized in grey. While it's
  open, the app is in the Dock and Cmd-Tab like any other. It asks macOS to keep it out of screenshots and screen
  sharing, which some screen-sharing apps may not honor; turn that off in Settings to take a screenshot of it. The menu
  bar icon, red dot and all, is kept out of them the same way, unless turned off in Settings.
- A notification says when a recording starts and when it's saved. Click the "saved" one to show the file in Finder.
  Some have buttons, under Options: **Record Now** and **Skip** on a meeting about to start, **Stop Recording** on a
  recording that started, **Try Again** when one could not start, and **Open Transcript** and **Restore Recording**
  once a recording went to the Trash.
  While it records, the menu bar icon has a red dot.
- **Settings** has a tab each for where recordings go (`~/Meetings` by default) and when they start, which calendars,
  the format and the mic, the transcript's language and identifying speakers, and the version. Recordings go in the
  same tree `record-meetings` uses: `CALENDAR/WEEK-YEAR/MM-DD/HHhMM-name/` for a meeting on the calendar, by when it was
  meant to start, so a restarted meeting lands next to the first recording, and the same under its calendar for one
  started from the menu (`WEEK-YEAR/...` straight under the folder when no calendar is recorded).
- Once a recording's transcript is complete, the recording goes to the Trash and only the transcript stays, unless
  turned off in Settings › Recording. One whose transcript stopped short, or has no words in it, is kept.
- After a crash or a forced quit, the menu offers to save any recording that was left unsaved.

It needs Xcode to build (`make build-app`, or `make build` for the tools and the app together, then `make install-app`
to copy it into `~/Applications`). On its first recording,
macOS asks it for Microphone and System Audio Recording; it asks for Calendars when it first opens.

**Formats.** Every format but CAF costs a conversion. Recordings are captured as CAF (48 kHz, 16-bit PCM), about 690 MB
an hour, and converted while they record, so stopping takes no time. But converting uses CPU the whole time, and a
conversion that falls behind is done over when the recording stops. For the best results, use CAF: no conversion and
nothing lost. For small files, use M4A, which macOS converts itself (about 60 MB an hour). MP3 needs ffmpeg.

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
transcribe speakers [name <number> <name> | merge <number> <into-number> [--anyway] | forget <number>]
transcribe speakers [split <voice> | play <number> | save <number> <directory>]
transcribe --list-languages
```

| Option | Effect |
| --- | --- |
| `--language LANG` | Language spoken, e.g. `es` or `es-MX` (default `en-US`) |
| `--mix` | Transcribe both channels together, without speaker labels |
| `--identify-speakers` | Tell people apart by voice: `Them 1`, `Them 2`, ... (`Speaker 1`, `Speaker 2`, ... on a recording without the split, or with `--mix`). Everyone is saved as they are heard, in `~/.transcribe/speakers.db`, so they keep their number from call to call. It runs on your mic too, for when several of you share it; a line it cannot tell yet stays `You` or `Them`. Voiceprints are biometric data; see [Recording laws](#recording-laws) |
| `speakers` | List the people `--identify-speakers` remembers, with the voices of those heard more than one way; `name 3 Ada` names one, `merge 5 3` makes 5 part of 3, keeping each voice as it was (two who don't sound alike need `--anyway`), `split 7` takes voice 7 back out into a person of its own, `forget 5` takes one out |
| `speakers play 3`, `speakers save 3 <directory>` | Play the clips kept of someone, their 20 longest stretches of speech of up to 15 s, to tell who they are; or save them as `.m4a` files |
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
  `transcribe speakers name`. Short clips of everyone's speech are kept in `~/.transcribe/speakers.db` too, so you can tell who
  they are with `transcribe speakers play`; `transcribe speakers forget` deletes them along with the person.
- **Saving is quick.** `totalrecall` records into `<output>.partial.caf` and converts to the format you asked for as it
  records, so Ctrl-C saves in well under a second instead of about 15 s per hour of audio. `.caf` needs no conversion.
  If converting fails or falls behind, it converts the whole recording when you stop instead, as before.
- **The stream ending doesn't end the recording.** With `--stream`, if the program reading it exits, `totalrecall` says
  so and keeps recording the file.
- **AirPods sound lower quality.** Their Bluetooth call profile records at about 24 kHz. That's fine for transcripts,
  but the Mac mic is clearer in a quiet room.
- **Headphones beat echo cancellation.** Echo cancellation reduces the "everyone twice" effect a lot, but not
  completely.
- **The first transcription in a language takes longer** while Apple's speech model downloads.
- **Tell people you're recording.** Some places require everyone's consent; see [Recording laws](#recording-laws).

## Recording laws

totalrecall runs only on your Mac, so nothing is sent to anyone, but you are the one recording, and following the law
where you and the people on the call are is up to you. This is a summary, not legal advice:

- **Recording a call.** US federal law, and most states, let you record a conversation you're part of. California,
  Florida, Illinois, Maryland, Massachusetts, Montana, Nevada, New Hampshire, Pennsylvania, Washington and a few more
  require *everyone's* consent. When people are in different places, follow the strictest. In the EU and the UK, the
  GDPR requires telling people they're recorded, and at work your employer's policy decides whether you may. In
  Germany, secretly recording a private conversation is a crime, even one you're part of.
- **Keeping it.** Recordings, transcripts and summaries of them are all personal data under the GDPR: keep them only
  as long as you need them. Deleting a recording afterwards doesn't make it legal to have made it.
- **Identifying speakers.** `--identify-speakers`, and Identify Speakers in the app, save a voiceprint of everyone
  they hear, and clips of their speech, in `~/.transcribe/speakers.db` (the app in `~/Library/Application Support/TotalRecall/speakers.db`), to recognize them
  in later calls. A voiceprint is biometric data. Illinois's
  BIPA requires each person's written consent before you collect one, and Texas, Washington and the GDPR have rules of
  their own. Use it only on calls where everyone has agreed. `transcribe speakers forget` deletes a person, their
  voiceprints and their clips.

The simplest way to be safe anywhere: say at the start of the call that you're recording and transcribing it, and stop
if anyone objects.

## Credits

`transcribe --identify-speakers` tells voices apart with [WeSpeaker](https://github.com/wenet-e2e/wespeaker)'s
[ResNet34-LM speaker model](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), trained on
[VoxCeleb](https://www.robots.ox.ac.uk/~vgg/data/voxceleb/), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); it is converted to Core ML, unchanged otherwise.

## License

MIT; see [LICENSE](LICENSE). The speaker model keeps its own CC BY 4.0 license (see Credits).
