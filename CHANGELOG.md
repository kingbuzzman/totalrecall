# Changelog

Each release's notes on GitHub come from its section here (see `.github/workflows/release.yml`).

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
