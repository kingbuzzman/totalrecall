import Shared
import SwiftUI
import Transcribe

/// The people Identify Speakers remembers: naming them, hearing their clips, merging one person taken for two, which
/// asks first when their voices don't sound alike, splitting a voice back out of a wrong merge, and forgetting someone.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var people = People()
    /// A merge of two who don't sound alike, waiting to be confirmed.
    @State private var unlikeMerge: (person: People.Entry, into: People.Entry)?
    @State private var forgetting: People.Entry?
    /// Whether an audio file is being dragged over the window.
    @State private var isDropTarget = false

    var body: some View {
        Form {
            if people.entries.isEmpty {
                Section {
                    Text("Nobody yet. Identify Speakers, in Settings › Transcript, remembers the people it hears.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(people.entries) { entry in
                        PersonRow(
                            entry: entry,
                            others: others(than: entry),
                            people: people,
                            isRecording: model.isRecording,
                            merge: { merge(entry, into: $0) },
                            forget: { forgetting = entry }
                        )
                    }
                } footer: {
                    Text(
                        "Merging files one person's voices under another, each kept as it was, so a wrong merge can "
                            + "be split back out."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                if let file = people.learningFrom {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Learning the voices in \(file)…")
                    }
                } else {
                    Text(people.learned ?? "Drop a recording here to learn the voices in it.")
                        .foregroundStyle(.secondary)
                }
            }
            if let problem = people.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260, maxHeight: 560)
        .onAppear { people.reload() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: People.canLearn(from:)) else { return false }
            people.learnVoices(from: file)
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .onDisappear { people.stop() }
        // The recording would pick up what is played.
        .onChange(of: model.isRecording) { _, isRecording in if isRecording { people.stop() } }
        .alert(
            "\(unlikeMerge?.person.name ?? "") and \(unlikeMerge?.into.name ?? "") don't sound alike",
            isPresented: Binding(get: { unlikeMerge != nil }, set: { if !$0 { unlikeMerge = nil } })
        ) {
            Button("Merge Anyway") {
                if let unlikeMerge { people.merge(unlikeMerge.person.id, into: unlikeMerge.into.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are most likely two people. Listen to both first; a wrong merge can be split back out.")
        }
        .alert(
            "Forget \(forgetting?.name ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })
        ) {
            Button("Forget", role: .destructive) {
                if let forgetting { people.forget(forgetting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their voices and clips are deleted. If they are heard again, they come back as someone new.")
        }
    }

    /// Why nothing plays while recording.
    static let recordingHelp = "Can't play while recording: the recording would pick it up. Stop recording to listen."

    /// Everyone else, for Merge Into: those who sound like `entry`, the most alike first, then the rest, in order.
    private func others(than entry: People.Entry) -> (alike: [People.Entry], rest: [People.Entry]) {
        let others = people.entries.filter { $0.id != entry.id }
            .map { ($0, people.distance(entry.id, $0.id) ?? .infinity) }
        let alike = others.filter { $0.1 < SpeakerDatabase.soundAlike }.sorted { $0.1 < $1.1 }.map(\.0)
        let rest = others.filter { $0.1 >= SpeakerDatabase.soundAlike }.map(\.0).sorted { $0.id < $1.id }
        return (alike, rest)
    }

    /// Merges at once two who sound alike; asks first for two who don't.
    private func merge(_ entry: People.Entry, into target: People.Entry) {
        if people.soundAlike(entry.id, target.id) {
            people.merge(entry.id, into: target.id)
        } else {
            unlikeMerge = (entry, target)
        }
    }
}

/// One person: their name, to change; how long they were heard, their clips and voices; and what can be done with them.
private struct PersonRow: View {
    let entry: People.Entry
    let others: (alike: [People.Entry], rest: [People.Entry])
    let people: People
    /// Nothing is played while recording, which would pick it up.
    let isRecording: Bool
    let merge: (People.Entry) -> Void
    let forget: () -> Void
    @State private var name = ""
    @State private var showsClips = false
    /// Their clips, read when the list of them is opened.
    @State private var clips: [SpeakerDatabase.Clip] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $name, prompt: Text(entry.name))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.headline)
                    // Saved as it is typed, not only on Return, which clicking away or closing the window would skip.
                    .onChange(of: name) { _, typed in people.rename(entry.id, to: typed) }
                Spacer()
                // The explanation on the button's frame rather than the button, as a disabled one shows none.
                HStack {
                    Button(people.playing == entry.id ? "Stop" : "Play") { people.play(entry.id) }
                        .disabled(entry.clips == 0 || isRecording)
                }
                .help(playHelp)
                Menu("Merge Into") {
                    if !others.alike.isEmpty {
                        Section("Sounds alike") {
                            ForEach(others.alike) { other in Button(mergeLabel(other)) { merge(other) } }
                        }
                    }
                    Section(others.alike.isEmpty ? "" : "Others") {
                        ForEach(others.rest) { other in Button(mergeLabel(other)) { merge(other) } }
                    }
                }
                .fixedSize()
                .disabled(others.alike.isEmpty && others.rest.isEmpty)
                Button("Forget", role: .destructive, action: forget)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.clips > 0 {
                DisclosureGroup(isExpanded: $showsClips) {
                    ForEach(clips, id: \.id) { clip in
                        ClipRow(
                            clip: clip,
                            voiceNumber: entry.voices.count > 1 ? clip.voice : nil,
                            isPlaying: people.playingClip == clip.id,
                            isRecording: isRecording,
                            play: { people.play(clip, of: entry.id) }
                        )
                    }
                } label: {
                    Text("Clips").font(.caption)
                }
                .onChange(of: showsClips) { _, shows in if shows { clips = people.clips(of: entry.id) } }
                .onChange(of: entry.clips) { _, _ in if showsClips { clips = people.clips(of: entry.id) } }
            }
            if entry.voices.count > 1 {
                ForEach(entry.voices, id: \.id) { voice in
                    HStack {
                        Text("Voice \(voice.id) · \(heard(Double(voice.prints) * SpeakerDatabase.secondsPerPrint))")
                            .font(.caption)
                        Spacer()
                        Button("Split Out") { people.split(voice: voice.id) }
                            .controlSize(.small)
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { name = entry.person.name ?? "" }
        // Such as a name given from elsewhere; not the spaces of a name being typed, which are saved trimmed.
        .onChange(of: entry.person.name) { _, saved in
            if name.trimmingCharacters(in: .whitespaces) != (saved ?? "") { name = saved ?? "" }
        }
    }

    /// "Them 3 · 82%": someone to merge into, and how alike they sound.
    private func mergeLabel(_ other: People.Entry) -> String {
        people.similarity(entry.id, other.id).map { "\(other.name) · \($0)%" } ?? other.name
    }

    private var playHelp: String {
        if isRecording { return PeopleView.recordingHelp }
        if entry.clips == 0 { return "No clips of them yet: they are kept from stretches of their speech." }
        return "Plays their clips, longest first"
    }

    /// "You · heard 4 min · 3 clips · 2 voices · since Nov 12, 2026".
    private var summary: String {
        var parts = entry.person.isYou && entry.person.name != nil ? ["You"] : []
        parts.append("heard \(heard(entry.heardSeconds))")
        parts.append(entry.clips > 0 ? counted(entry.clips, "clip") : "no clips yet")
        if entry.voices.count > 1 { parts.append(counted(entry.voices.count, "voice")) }
        parts.append("since \(entry.person.createdAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    private func heard(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }
}

/// One clip of someone: how long, when it was recorded, which of their voices when they have several, and a button to
/// hear it, but not while recording.
private struct ClipRow: View {
    let clip: SpeakerDatabase.Clip
    let voiceNumber: Int?
    let isPlaying: Bool
    let isRecording: Bool
    let play: () -> Void

    var body: some View {
        HStack {
            Text(description).font(.caption).monospacedDigit()
            Spacer()
            // The explanation on the button's frame rather than the button, as a disabled one shows none.
            HStack {
                Button(isPlaying ? "Stop" : "Play", action: play)
                    .controlSize(.small)
                    .disabled(isRecording)
            }
            .help(isRecording ? PeopleView.recordingHelp : "Plays this clip")
        }
    }

    /// "12 s · Nov 16, 8:07 AM · voice 2".
    private var description: String {
        let length = "\(Int(clip.seconds.rounded())) s"
        var parts = [length, clip.recordedAt.formatted(date: .abbreviated, time: .shortened)]
        if let voiceNumber { parts.append("voice \(voiceNumber)") }
        return parts.joined(separator: " · ")
    }
}
