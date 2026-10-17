# Changelog

Each release's notes on GitHub come from its section here (see `.github/workflows/release.yml`).

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
