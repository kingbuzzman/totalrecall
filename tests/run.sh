#!/bin/bash
# Integration tests for totalrecall. They drive the real binary against fake microphones (see tests/audiolab) and
# check the files it saves, so they test behavior, not implementation: any version that passes is not broken.
#
# Needs no real microphone or speakers, only BlackHole loopback devices, so it runs on headless CI machines:
#   brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch
#
# Usage: tests/run.sh [scenario ...]     (default: all; LONG=1 adds the long-running drift test)
#
# Without the devices it fails, unless SKIP_MISSING_DEVICES=1: then it runs only the scenarios that need none and,
# if they pass, exits 3 to say the others were skipped.
#
# While it runs, the system input and output are switched to the test devices; both are restored on exit.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
totalrecall="${TOTALRECALL:-$root/totalrecall}"
audiolab="$root/tests/build/audiolab"
results="${RESULTS:-$root/tests/build/results}"

mic_a_loopback="${MIC_A_LOOPBACK:-BlackHole 2ch}"
mic_b_loopback="${MIC_B_LOOPBACK:-BlackHole 16ch}"
speakers="${SPEAKERS:-BlackHole 64ch}"

mic_a="audiolab A"
mic_b="audiolab B"
pitch_a=1000
pitch_b=1500
pitch_system=3000
system_offset_ms=50

# A device switch that cannot overlap (the old device is gone or restarting) may lose this much audio.
restart_gap_ms=500

background_pids=()
recorder_pid=""
failures=0
scenario_failed=0
failed_scenarios=()
skipped_scenarios=()

log() { printf '%s\n' "$*"; }

# MARK: - Process helpers

start_background() {
    local log_file="$1"
    shift
    "$@" >"$log_file" 2>&1 &
    last_pid=$!
    background_pids+=("$last_pid")
}

stop_process() {
    local pid="$1"
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

# start_fake_mic NAME LOOPBACK PITCH [audiolab fake-mic options...]; sets fake_mic_pid
start_fake_mic() {
    local name="$1" loopback="$2" pitch="$3"
    shift 3
    start_background "$results/fake-mic-${name// /-}.log" "$audiolab" fake-mic --name "$name" --loopback "$loopback" --pitch "$pitch" "$@"
    fake_mic_pid=$last_pid
    "$audiolab" wait-device "$name"
}

stop_fake_mic() {
    local pid="$1" name="$2"
    stop_process "$pid"
    "$audiolab" wait-gone "$name"
}

# start_recording FILE [totalrecall options...]; waits until totalrecall is capturing
start_recording() {
    local file="$1"
    shift
    "$totalrecall" --force "$@" "$file" 2>"$file.log" &
    recorder_pid=$!
    local waited=0
    until grep -q 'Press Ctrl-C' "$file.log" 2>/dev/null; do
        if ! kill -0 "$recorder_pid" 2>/dev/null || [ "$waited" -ge 100 ]; then
            fail "totalrecall did not start: $(cat "$file.log")"
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

# stop_recording [SIGNAL]; sets recorder_status
stop_recording() {
    kill -"${1:-INT}" "$recorder_pid"
    wait "$recorder_pid"
    recorder_status=$?
    recorder_pid=""
}

# MARK: - Assertions

fail() {
    log "    FAIL $*"
    scenario_failed=1
}

pass() {
    log "    ok   $*"
}

# expect DESCRIPTION COMMAND...: the command must succeed; its output is shown either way
expect() {
    local description="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        [ -n "$output" ] && log "$output"
        pass "$description"
    else
        [ -n "$output" ] && log "$output"
        fail "$description"
    fi
}

expect_exit() {
    local expected="$1" description="$2"
    shift 2
    "$@" >/dev/null 2>&1
    local status=$?
    if [ "$status" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (exit $status, expected $expected)"
    fi
}

expect_status() {
    local description="$1"
    if [ "$recorder_status" -eq 0 ]; then
        pass "$description"
    else
        fail "$description (totalrecall exited $recorder_status): $(tail -3 "$2.log")"
    fi
}

expect_at_least() {
    local description="$1" actual="$2" minimum="$3"
    if awk -v actual="$actual" -v minimum="$minimum" 'BEGIN { exit !(actual >= minimum) }'; then
        pass "$description ($actual >= $minimum)"
    else
        fail "$description ($actual < $minimum)"
    fi
}

info_field() {
    "$audiolab" info "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# MARK: - Scenarios

scenario_rejects_bad_usage() {
    expect_exit 1 "no output file" "$totalrecall"
    expect_exit 1 "unknown --mic" "$totalrecall" --mic "no such microphone" "$results/unused.wav"
    expect_exit 1 "missing output directory" "$totalrecall" "$results/no-such-directory/out.wav"
    local existing="$results/existing.wav"
    printf 'keep me' >"$existing"
    expect_exit 1 "existing file without --force" "$totalrecall" "$existing"
    if [ "$(cat "$existing")" = "keep me" ]; then pass "existing file left untouched"; else fail "existing file was modified"; fi
}

scenario_records_mic_and_system_audio() {
    local file="$results/baseline.wav"
    start_recording "$file" --no-echo-cancellation || return
    sleep 6
    stop_recording
    expect_status "saved on Ctrl-C" "$file"
    expect "mic on the left, continuous" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a" --skip-start 0.5 --skip-end 0.3 --max-gap 0 --max-skips 0 --min-clicks 45
    expect "system audio on the right, continuous" "$audiolab" analyze "$file" --channel right --pitches "$pitch_system" --skip-start 0.5 --skip-end 0.3 --max-gap 0 --max-skips 0 --min-clicks 45
    expect "channels stay in sync" "$audiolab" sync "$file" --left-pitches "$pitch_a" --right-pitch "$pitch_system" --max-drift 10
}

scenario_switches_to_new_system_input() {
    local file="$results/switch.wav"
    start_fake_mic "$mic_b" "$mic_b_loopback" "$pitch_b"
    local mic_b_pid=$fake_mic_pid
    start_recording "$file" --no-echo-cancellation || return
    sleep 2
    "$audiolab" set-input "$mic_b"
    sleep 4
    stop_recording
    "$audiolab" set-input "$mic_a"
    stop_fake_mic "$mic_b_pid" "$mic_b"
    expect_status "saved on Ctrl-C" "$file"
    expect "switches A -> B with no lost audio" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a,$pitch_b" --skip-start 0.5 --skip-end 0.3 --expect-order "$pitch_a,$pitch_b" --max-gap 0 --max-skips 0
}

# AirPods deliver silence for ~2 s while Bluetooth switches to the call profile; the old mic must cover that time.
scenario_switches_to_slow_starting_input() {
    local file="$results/switch-slow.wav"
    start_fake_mic "$mic_b" "$mic_b_loopback" "$pitch_b" --silent-for 4
    local mic_b_pid=$fake_mic_pid
    start_recording "$file" --no-echo-cancellation || return
    sleep 1.5
    "$audiolab" set-input "$mic_b"
    sleep 5
    stop_recording
    "$audiolab" set-input "$mic_a"
    stop_fake_mic "$mic_b_pid" "$mic_b"
    expect_status "saved on Ctrl-C" "$file"
    expect "old mic covers the new mic's silent start" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a,$pitch_b" --skip-start 0.5 --skip-end 0.3 --expect-order "$pitch_a,$pitch_b" --max-gap 0 --max-skips 0
}

scenario_survives_sample_rate_changes() {
    local file="$results/rate-change.wav"
    start_recording "$file" --no-echo-cancellation || return
    sleep 2
    "$audiolab" set-rate "$mic_a" 44100
    sleep 2
    "$audiolab" set-rate "$mic_a" 48000
    sleep 3
    stop_recording
    expect_status "saved on Ctrl-C" "$file"
    expect "keeps recording through two rate changes" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a" --skip-start 0.5 --skip-end 0.3 --max-gap $((2 * restart_gap_ms)) --min-clicks 50
    expect "recording is still on the grid afterwards" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a" --tail 2 --skip-end 0.3 --max-gap 0 --max-skips 0
}

scenario_prefers_named_mic_while_present() {
    local file="$results/preferred.wav"
    start_fake_mic "$mic_b" "$mic_b_loopback" "$pitch_b"
    local mic_b_pid=$fake_mic_pid
    start_recording "$file" --no-echo-cancellation --mic "$mic_b" || return
    sleep 2
    stop_fake_mic "$mic_b_pid" "$mic_b"
    sleep 2
    start_fake_mic "$mic_b" "$mic_b_loopback" "$pitch_b"
    mic_b_pid=$fake_mic_pid
    sleep 3
    stop_recording
    stop_fake_mic "$mic_b_pid" "$mic_b"
    expect_status "saved on Ctrl-C" "$file"
    expect "B, falls back to the system input when B disappears, back to B when it returns" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a,$pitch_b" --skip-start 0.5 --skip-end 0.3 --expect-order "$pitch_b,$pitch_a,$pitch_b" --max-gap "$restart_gap_ms"
}

scenario_survives_rapid_switching() {
    local file="$results/flapping.wav"
    start_fake_mic "$mic_b" "$mic_b_loopback" "$pitch_b"
    local mic_b_pid=$fake_mic_pid
    start_recording "$file" --no-echo-cancellation || return
    local switch
    for switch in 1 2 3 4 5 6 7 8 9 10; do
        "$audiolab" set-input "$mic_b"
        sleep 0.15
        "$audiolab" set-input "$mic_a"
        sleep 0.15
    done
    "$audiolab" set-input "$mic_b"
    sleep 3
    stop_recording
    "$audiolab" set-input "$mic_a"
    stop_fake_mic "$mic_b_pid" "$mic_b"
    expect_status "saved on Ctrl-C" "$file"
    expect "ends on the last selected input" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a,$pitch_b" --tail 1.5 --skip-end 0.3 --expect-order "$pitch_b" --max-gap 0
}

# The fake mic hears the system clicks 60 ms late at -12 dB, like a laptop mic hearing its speakers.
scenario_cancels_speaker_echo() {
    local echo_mic="audiolab echo"
    start_fake_mic "$echo_mic" "$mic_b_loopback" "$pitch_b" --echo-pitch "$pitch_system" --echo-offset $((system_offset_ms + 60)) --echo-gain -12
    local echo_mic_pid=$fake_mic_pid
    "$audiolab" set-input "$echo_mic"
    local raw="$results/echo-raw.wav" cancelled="$results/echo-cancelled.wav"
    start_recording "$raw" --no-echo-cancellation || return
    sleep 6
    stop_recording
    start_recording "$cancelled" || return
    sleep 6
    stop_recording
    "$audiolab" set-input "$mic_a"
    stop_fake_mic "$echo_mic_pid" "$echo_mic"
    expect_status "saved on Ctrl-C" "$cancelled"
    local raw_echo cancelled_echo
    raw_echo=$("$audiolab" level "$raw" --channel left --pitch "$pitch_system" --skip-start 2)
    cancelled_echo=$("$audiolab" level "$cancelled" --channel left --pitch "$pitch_system" --skip-start 2)
    log "    echo on the mic channel: ${raw_echo} dB raw, ${cancelled_echo} dB with echo cancellation"
    expect_at_least "echo reduced by at least 10 dB" "$(awk -v raw="$raw_echo" -v cancelled="$cancelled_echo" 'BEGIN { print raw - cancelled }')" 10
}

scenario_saves_on_every_stop_signal() {
    local stop_signal file
    for stop_signal in INT TERM HUP; do
        file="$results/signal-$stop_signal.wav"
        start_recording "$file" --no-echo-cancellation || return
        sleep 2
        stop_recording "$stop_signal"
        expect_status "SIG$stop_signal saves the recording" "$file"
        expect_at_least "SIG$stop_signal recording length (s)" "$(info_field "$file" duration)" 1.5
        if [ -e "$file.partial.caf" ]; then fail "SIG$stop_signal left $file.partial.caf behind"; fi
    done
}

scenario_hard_kill_keeps_partial_recording() {
    local file="$results/killed.wav"
    start_recording "$file" --no-echo-cancellation || return
    sleep 2.5
    stop_recording KILL
    expect "the .partial.caf is readable" "$audiolab" info "$file.partial.caf"
    expect_at_least "partial recording length (s)" "$(info_field "$file.partial.caf" duration)" 1.5
    expect "the partial recording has the system audio" "$audiolab" analyze "$file.partial.caf" --channel right --pitches "$pitch_system" --min-clicks 15
}

scenario_writes_every_output_format() {
    local extension expected_format file
    for extension in m4a wav aiff caf mp3 flac; do
        case "$extension" in
            m4a) expected_format=aac ;;
            mp3) expected_format=.mp3 ;;
            flac) expected_format=flac ;;
            *) expected_format=lpcm ;;
        esac
        file="$results/format.$extension"
        start_recording "$file" --no-echo-cancellation || return
        sleep 2.5
        stop_recording
        expect_status ".$extension saved" "$file"
        local summary
        summary=$("$audiolab" info "$file")
        case "$summary" in
            "format=$expected_format channels=2 rate=48000 "*) pass ".$extension is $expected_format, stereo, 48 kHz" ;;
            *) fail ".$extension: $summary" ;;
        esac
        expect ".$extension keeps the audio" "$audiolab" analyze "$file" --channel right --pitches "$pitch_system" --min-clicks 15
    done
}

scenario_mixes_channels_without_isolation() {
    local file="$results/mixed.wav"
    start_recording "$file" --no-echo-cancellation --no-speaker-isolation || return
    sleep 4
    stop_recording
    expect_status "saved on Ctrl-C" "$file"
    expect "left has the mic" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a" --skip-start 0.5 --min-clicks 30
    expect "left has the system audio" "$audiolab" analyze "$file" --channel left --pitches "$pitch_system" --skip-start 0.5 --min-clicks 30
    expect "right has the mic" "$audiolab" analyze "$file" --channel right --pitches "$pitch_a" --skip-start 0.5 --min-clicks 30
}

scenario_long_recording_stays_in_sync() {
    local file="$results/long.wav"
    start_recording "$file" --no-echo-cancellation || return
    sleep 120
    stop_recording
    expect_status "saved on Ctrl-C" "$file"
    expect "no lost audio over 2 minutes" "$audiolab" analyze "$file" --channel left --pitches "$pitch_a" --skip-start 0.5 --skip-end 0.3 --max-gap 0 --max-skips 0
    expect "channels stay in sync over 2 minutes" "$audiolab" sync "$file" --left-pitches "$pitch_a" --right-pitch "$pitch_system" --max-drift 20
    local duration
    duration=$(info_field "$file" duration)
    expect_at_least "recording length matches wall clock (s)" "$duration" 119
}

all_scenarios=(
    rejects_bad_usage
    records_mic_and_system_audio
    switches_to_new_system_input
    switches_to_slow_starting_input
    survives_sample_rate_changes
    prefers_named_mic_while_present
    survives_rapid_switching
    cancels_speaker_echo
    saves_on_every_stop_signal
    hard_kill_keeps_partial_recording
    writes_every_output_format
    mixes_channels_without_isolation
)
if [ "${LONG:-0}" = 1 ]; then all_scenarios+=(long_recording_stays_in_sync); fi
# totalrecall rejects these before it touches an audio device.
device_free_scenarios=(rejects_bad_usage)

# MARK: - Setup and teardown

original_input=""
original_output=""

teardown() {
    if [ -n "$recorder_pid" ]; then kill -INT "$recorder_pid" 2>/dev/null; wait "$recorder_pid" 2>/dev/null; fi
    local pid
    for pid in ${background_pids[@]+"${background_pids[@]}"}; do kill -TERM "$pid" 2>/dev/null; done
    for pid in ${background_pids[@]+"${background_pids[@]}"}; do wait "$pid" 2>/dev/null; done
    "$audiolab" cleanup
    if [ -n "$original_input" ] && "$audiolab" has-device "$original_input"; then "$audiolab" set-input "$original_input"; fi
    if [ -n "$original_output" ] && "$audiolab" has-device "$original_output"; then "$audiolab" set-output "$original_output"; fi
}

for required in "$totalrecall" "$audiolab"; do
    if [ ! -x "$required" ]; then
        log "missing $required; run: make test"
        exit 2
    fi
done
missing_devices=()
for device in "$mic_a_loopback" "$mic_b_loopback" "$speakers"; do
    if ! "$audiolab" has-device "$device"; then missing_devices+=("$device"); fi
done
if [ ${#missing_devices[@]} -gt 0 ]; then
    log "missing audio devices: ${missing_devices[*]}; install the test devices with:"
    log "  brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch"
    if [ "${SKIP_MISSING_DEVICES:-0}" != 1 ]; then exit 2; fi
    log "running only the scenarios that need no devices: ${device_free_scenarios[*]}"
fi

mkdir -p "$results"
trap teardown EXIT
trap 'exit 130' INT TERM

"$audiolab" cleanup
if [ ${#missing_devices[@]} -eq 0 ]; then
    original_input=$("$audiolab" default-input)
    original_output=$("$audiolab" default-output)
    "$audiolab" set-output "$speakers" || exit 2
    start_background "$results/system-clicks.log" "$audiolab" play --device "$speakers" --pitch "$pitch_system" --offset "$system_offset_ms"
    start_fake_mic "$mic_a" "$mic_a_loopback" "$pitch_a" || exit 2
    "$audiolab" set-input "$mic_a" || exit 2
fi

selected_scenarios=("$@")
if [ ${#selected_scenarios[@]} -eq 0 ]; then selected_scenarios=("${all_scenarios[@]}"); fi

for scenario in "${selected_scenarios[@]}"; do
    if ! declare -F "scenario_$scenario" >/dev/null; then
        log "unknown scenario: $scenario (available: ${all_scenarios[*]} long_recording_stays_in_sync)"
        exit 2
    fi
    if [ ${#missing_devices[@]} -gt 0 ] && [[ " ${device_free_scenarios[*]} " != *" $scenario "* ]]; then
        skipped_scenarios+=("$scenario")
        continue
    fi
    log "▶ $scenario"
    scenario_failed=0
    "scenario_$scenario"
    if [ "$scenario_failed" -ne 0 ]; then
        failures=$((failures + 1))
        failed_scenarios+=("$scenario")
    fi
done

log ""
ran=$((${#selected_scenarios[@]} - ${#skipped_scenarios[@]}))
if [ ${#skipped_scenarios[@]} -gt 0 ]; then
    log "skipped ${#skipped_scenarios[@]} scenarios that need the test devices: ${skipped_scenarios[*]}"
fi
if [ "$failures" -ne 0 ]; then
    log "$failures of $ran scenarios failed: ${failed_scenarios[*]} (recordings and logs in $results)"
    exit 1
fi
log "all $ran scenarios passed (recordings in $results)"
if [ ${#skipped_scenarios[@]} -gt 0 ]; then exit 3; fi
