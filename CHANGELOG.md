# Changelog

Each release's notes on GitHub come from its section here (see `.github/workflows/release.yml`).

## Unreleased

## 0.6.0

### transcribe

- Remembered speakers start over in a new layout.
- `merge` folds one person's voice and clips into another's; it refuses voices that don't sound alike unless `--anyway`.
- Each clip keeps its print; clips unlike the rest of their person's are flagged; `transcribe speakers forget-clip` removes one.
- Up to 20 clips are kept per person, named or not.
- On your microphone, a voice not saved yet is "You", not "Them": AirPods sounding different after a pause no longer turn you into someone else.
- Someone new is saved only together with a clip of them: at least 5 s of them alone, speaking without a pause.
- Who talks when comes from a segmentation model, overlap included; lines split where the speaker changes.
- When a call ends, voices are regrouped and the transcript rewritten; new people are saved then (`Them A` until then).
- Voice prints run on the Neural Engine.

### TotalRecall.app

- With Identify Speakers, the transcript window shows the rewritten transcript when the recording ends.
- Start Recording and New Meeting… file the recording under the default meeting calendar, chosen in Settings (the
  first calendar recorded until then), instead of `other/`; with no calendar recorded, it goes straight under the
  recordings folder, by week. Holding ⌘ with the menu open turns them into Start Recording On… and New Meeting On…,
  which ask for the calendar, to pick another for one recording.
- New Meeting… suggests the last name given, and puts the meeting on its calendar, from when it starts until it's
  stopped; until then it lasts the default meeting length, 30 minutes unless changed in Settings. Start Recording
  only records. New Meeting… is in the menu while a calendar is turned on, and the ⌘ items while there are two or
  more to pick from.
- Read-only calendars, such as holidays, which events can't be added to, are greyed out in Settings and never
  recorded.
- Submenus, such as Today, stay open while recording; the elapsed time pauses while the pointer is on an item.
- Open Recordings Folder is gone from the menu; Show, beside the folder in Settings, opens it.
- Delete Recordings Once Transcribed, in Settings › Recording, on unless turned off: each recording goes to the Trash
  once its transcript is complete, keeping only the transcript. One whose transcript stopped short, or has no words in
  it, is kept.
- Settings and remembered speakers live in `~/Library/Application Support/TotalRecall/`.
- Each calendar's settings are saved as plain dictionaries rather than encoded data.
- Notifications have buttons: Record Now and Skip on a meeting about to start (Record Now stops whatever is being
  recorded first), Stop Recording on a recording that started, Try Again when one could not start, and Open
  Transcript and Restore Recording, which takes it back out of the Trash, once a recording went to the Trash.
- Start Now is gone from the menu too: Record Now, on the meeting in Today, does the same.
- The transcript's first line no longer hides under the column headers.
- The transcript window's recording time keeps counting while the menu is closed.
- Recording starts as soon as the system audio and the microphone run, which start at once: under a second with the Mac's microphone, about 3 s with AirPods, down from 4–6 s. The noise suppressor learns the room as it records.
- The transcript gives every speaker a color of their own, kept for the whole transcript: blues for your microphone, whatever your name, other colors for everyone else, chosen to be told apart with red-blue color blindness.
- The menu bar icon shows a red ring while a recording starts, and the red dot only once it records.
- The transcript keeps up while no window is open: macOS no longer naps the app while it records or transcribes, nor sleeps the Mac mid-meeting.
- A People window, from the transcript or Settings › Transcript, names, plays and merges the people Identify Speakers remembers, and flags and removes clips of someone else.
- Dropping a recording on the People window learns the voices in it.
- The app, `totalrecall` and `transcribe` log to Console under `local.totalrecall`; macOS keeps only the errors.

## 0.5.0

### TotalRecall.app

- A menu bar app that records and transcribes meetings, like `scripts/record-meetings -n`: Start Recording, New
  Meeting… (with a name), Stop Recording, and Continue for the last meeting, which records into its folder as `rec-2`.
  A window shows the transcript as it's written. Notifications say when a recording starts and when it's saved.
  Settings set the save folder, the audio format (with what each one costs), the mic, the language, identifying
  speakers, and opening at login. It runs the recorder and the transcriber in its own process. Each release has it as
  `TotalRecall-<version>-macos-arm64.zip`; or build it with `make build-app` (needs Xcode) and install it with
  `make install-app`.
- Reads today's meetings from Calendar.app, with every account it has, through EventKit, so it needs no icalbuddy:
  warns of each a few minutes before (5 unless changed), with a chime, and records it when it starts, if nothing else
  is being recorded, into the same folders `record-meetings` uses. It never stops a recording on its own. The menu shows
  the next meeting, with Start Now for one that starts early, and lists today's, to record one now or skip it.
  Recording automatically, the warning, and which calendars count are in Settings.
- Each calendar is set up on its own in Settings, told apart from others of the same title: whether its meetings are
  recorded (holidays and birthdays start off), whether focus time and prep blocks are ignored, and words or phrases
  to ignore meetings by, such as "1:1", or regular expressions between slashes, such as `/^1:1/`. Test shows the
  meetings a rule would ignore on that calendar, from two weeks back to two weeks ahead. Always Ignore Meetings Like
  This, on a meeting in Today, adds its title.
- Settings has tabs: General, Calendars, Recording, Transcript, and About, with the version.
- Turning on Identify Speakers asks first, and says why: it saves everyone's voiceprints, which laws such as
  Illinois's BIPA and the GDPR only allow with their consent.
- The transcript window is a table of time, speaker and words, your lines in blue and everyone else's in orange. It
  asks macOS to keep it out of screenshots and screen sharing (on unless turned off in Settings), which some
  screen-sharing apps may not honor. So is the menu bar icon, with its red dot while recording.
- Show Transcript is in the menu only while recording. While the transcript or Settings is open, the app is in the Dock
  and Cmd-Tab.
- Stopping returns at once: the file is saved and the transcript finished in the background, so the next recording can
  start straight away.
- After a crash or a forced quit, the menu offers to save recordings that were left unsaved. It never replaces a file
  that already exists, and it leaves alone any recording written to in the last two minutes.

### totalrecall

- Converts to the output format while it records, so Ctrl-C saves in well under a second instead of about 15 s per
  hour of audio (16 s an hour for `.mp3`, 20 s for `.m4a`). The `.partial.caf` is still written, and if converting
  fails or falls behind, the whole recording is converted when you stop instead, as before.
- `.flac` is encoded by macOS itself, without ffmpeg. Only `.mp3` and other formats macOS can't write still need it.
- ffmpeg is found in Homebrew's folders even when it isn't on the `PATH`.

## 0.4.0

### transcribe

- `--identify-speakers` tells people apart by voice: `Them 1`, `Them 2`, ... (`Speaker 1`, ... with `--mix` or on a
  recording without the You/Them split). It runs on both channels, so several people on your mic or on the call each
  get their own number. Everyone is saved in `~/.transcribe/speakers.db` as they are heard, so they keep their number
  from call to call. The speaker model is built into `transcribe`: there is nothing more to install or download, and
  no Python.
  - It is cautious: someone only becomes a new person after a few seconds of a voice unlike everyone so far, and only
    stays one if they said enough words. Notification pings, hum, music and other sounds without speech are not taken
    for people.
  - When a run ends, people with no name who surely are the same person are merged.
  - A voice-detection failure prints a warning on stderr; the transcript goes on without speaker numbers.
- `transcribe speakers` lists the people it remembers, and flags pairs that sound alike. `name 3 Ada` names one,
  `merge 5 3` makes 5 part of 3, and `forget 5` takes one out.
- `transcribe speakers play 3` plays the 4 longest samples kept of someone with no name yet, to tell who they are;
  `speakers save 3 <directory>` saves them as `.m4a` files. A person's samples are deleted once they are named.
- What your microphone picks up from your speakers is left out of your lines: a line that repeats what the call was
  saying at that moment, or one far quieter than the call, however garbled. So each of your lines waits a few seconds
  to settle; with `--live`, it stays on the live line, in grey, until it does.

## 0.3.1

- `make install` copies the tools into `~/.local/bin` instead of symlinking them to `build/bin`, so they keep working
  after `make clean` and don't change under you with each rebuild. Run it again to replace the old symlinks.

## 0.3.0

Changes how `transcribe` prints, and what both tools accept; see the commands to use now below.

### totalrecall

- `--stream` saves the file and streams the recording at the same time:
  `totalrecall meeting.mp3 --stream | transcribe -`. If the program reading the stream exits, totalrecall keeps
  recording the file. `totalrecall -` still streams without saving a file.
- Refuses to record when stdout is a pipe but nothing would go into it, such as
  `totalrecall meeting.mp3 | transcribe -`: add `--stream`.
- Lighter on the audio threads: the captures allocate less per buffer, a 48 kHz microphone skips resampling
  altogether, and the echo canceller no longer warms up while holding a lock the captures wait on, which held them up
  for up to about 50 ms as each recording started. Recordings are unchanged, sample for sample.
- Streaming with `totalrecall -` encodes the audio about 17 times faster.

### transcribe

- Prints each line the moment the recognizer settles on it, in that order, for files too (before, a file's transcript
  came all at once at the end, sorted by time). With the You/Them split, lines can come out of time order.
- A `<text-file>` gets each line as it settles, so a transcript cut short keeps everything up to that point. It is never
  printed as well, unless with `--live`.
- `--live` shows the live transcript, with the words still being recognized: `totalrecall - | transcribe - --live`.
  Without it, `transcribe -` now prints only finished lines. With a `<text-file>`, it shows it live and saves it:
  `transcribe - meeting.txt --live`.
- Refuses to overwrite an existing `<text-file>` unless given `--force`, like totalrecall.
- `transcribe -` refuses to start when nothing is piped in.
- On a Mac without on-device speech recognition, such as a virtual machine, it says so, instead of reporting a missing
  speech model for every language.
- Reads a `totalrecall -` stream about 3 times faster, and mixes the channels for `--mix` about 7 times faster.
  Transcripts are unchanged.

## 0.2.2

### transcribe

- Ctrl-C on `totalrecall - | transcribe -` no longer drops the last words: transcribe waits for totalrecall to end the
  stream and finishes the transcript, so `transcribe - meeting.txt` writes the file (before, it wrote nothing) and
  `| tee -i meeting.txt` gets every line, for a live transcript that is also saved as it goes. A second Ctrl-C quits
  right away.

## 0.2.1

### totalrecall

- Fixed: when a microphone changed sample rate mid-recording (AirPods do when their mic turns on), up to half a second
  of its audio was recorded stretched or squeezed, shifting the mic channel out of sync by tens of milliseconds.
- All messages, such as mic switches, read `totalrecall: mic -> ...` on stderr, never with a timestamp, which looked
  like a line of the transcript. Errors that end the program also start on a clean line.
- No more `mic -> <same mic>` announcements when the microphone capture restarts without changing device.

### transcribe

- `--language LANG` transcribes other languages than English, such as `--language es` or `--language es-MX`;
  `--list-languages` lists the ones Apple's recognizer supports. The default stays US English.
- Fixed: transcribing with a speech model that was not downloaded yet failed with "the speech recognizer cannot take
  ... Hz audio" instead of downloading it.

## 0.2.0

### totalrecall

- Checks the System Audio Recording permission before recording. If macOS has not asked yet, it shows the prompt; if
  the permission is denied, totalrecall exits with an error saying where to allow it, instead of quietly recording
  silence. Apple has no public API for this permission, so this uses macOS's undocumented TCC functions; if a macOS
  update removes them, totalrecall records without the check.
- The "No system audio captured yet" warning is gone, replaced by that check.
- Messages start on a clean line, so they no longer run into `transcribe`'s in-progress text when both print to the
  same terminal. Write failures now read `totalrecall: write failed: ...`.

### transcribe

- Ignores results without words, such as the "." the recognizer reports for silence (no more `Them: .`).

## 0.1.0

First release: `totalrecall` and `transcribe` for macOS 26 on Apple Silicon.

### totalrecall

- Records everything the Mac plays plus your microphone into one stereo file, your mic on the left and everyone else on
  the right (`--no-speaker-isolation` mixes them). Uses Core Audio process taps: no loopback driver, nothing to
  reconfigure.
- Removes speaker echo from your mic channel and suppresses background noise (speexdsp). It learns the room from a
  second of ambient sound before the recording starts, so recordings no longer begin with fading hiss.
- The recording starts when the screen says so and ends on Ctrl-C: the counter and the saved file have the same length.
  It waits for the microphone to actually turn on (AirPods take a moment) before starting.
- Follows the system input, so AirPods in or out switch the mic mid-recording without losing audio; `--mic NAME`
  prefers one mic whenever it is connected.
- Survives crashes: audio goes to `<output>.partial.caf` while recording, which stays playable if the process dies.
- Saves `.m4a`, `.wav`, `.aiff` and `.caf` natively, and any other format through ffmpeg.
- `-` streams the recording to stdout as WAV while it is being made, for `transcribe -` or other programs.

### transcribe

- On-device speech to text with Apple's speech recognizer; nothing leaves the Mac.
- `totalrecall - | transcribe -` prints the transcript live, about a second behind the speakers.
- Labels who is talking (`You` / `Them`) from totalrecall's channel split, with timestamps; `--mix` gives one unlabeled
  transcript.
- Transcribes finished recordings too: `transcribe meeting.mp3 [meeting.txt]`.
