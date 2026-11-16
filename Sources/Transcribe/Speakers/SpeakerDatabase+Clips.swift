import Foundation

/// Clips: some seconds of each person's speech, alone, to hear who they are by, each with its print, to tell one that
/// is someone else's.
extension SpeakerDatabase {
    /// A clip's print in this model, and whose clip it is.
    package struct ClipPrint: Equatable, Sendable {
        package let id: Int
        package let person: Int
        package let seconds: Double
        package let print: [Float]
    }

    /// Keeps a clip of a voice's speech, `seconds` long, with its print, unless its person already has
    /// `clipsPerPerson` longer ones.
    func addClip(_ audio: Data, seconds: Double, print: [Float], to voice: Int) throws {
        try sqlite.transaction {
            try sqlite.execute(
                "INSERT INTO clips (voice_id, audio, seconds, recorded_at) VALUES (?, ?, ?, ?)",
                [.integer(voice), .data(audio), .real(seconds), .real(Date().timeIntervalSince1970)]
            )
            try sqlite.execute(
                "INSERT INTO clip_prints (clip_id, model, print) VALUES (?, ?, ?)",
                [.integer(sqlite.lastInsertedID), .text(model), .floats(print)]
            )
            if let person = try self.voice(voice, inAnyModel: true)?.person { try keepLongestClips(of: person) }
        }
    }

    /// Someone's clips, the longest first.
    package func clips(of person: Int) throws -> [Clip] {
        try sqlite.query(
            """
            SELECT clips.id, clips.voice_id, clips.audio, clips.seconds, clips.recorded_at
            FROM clips JOIN voices ON voices.id = clips.voice_id
            WHERE voices.person_id = ? ORDER BY clips.seconds DESC, clips.id
            """,
            [.integer(person)]
        ) { row in
            Clip(
                id: row.integer(0),
                voice: row.integer(1),
                audio: row.data(2),
                seconds: row.real(3),
                recordedAt: row.date(4)
            )
        }
    }

    /// How many clips each person has, by number; those with none are left out.
    package func clipCounts() throws -> [Int: Int] {
        Dictionary(
            uniqueKeysWithValues: try sqlite.query(
                "SELECT voices.person_id, count(*) FROM clips JOIN voices ON voices.id = clips.voice_id GROUP BY 1"
            ) { ($0.integer(0), $0.integer(1)) }
        )
    }

    /// Every clip's print in this model; clips kept before they had prints have none, and are left out.
    package func clipPrints() throws -> [ClipPrint] {
        try sqlite.query(
            """
            SELECT clips.id, voices.person_id, clips.seconds, clip_prints.print
            FROM clips JOIN voices ON voices.id = clips.voice_id
                JOIN clip_prints ON clip_prints.clip_id = clips.id AND clip_prints.model = ?
            ORDER BY clips.id
            """,
            [.text(model)]
        ) { ClipPrint(id: $0.integer(0), person: $0.integer(1), seconds: $0.real(2), print: $0.floats(3)) }
    }

    /// Takes a clip out, such as one of someone else, merged in by mistake. Their voice stays as it is: if it came out
    /// wrong too, forget them, and the next recording hears them again. False if there is no such clip.
    @discardableResult
    package func forgetClip(_ clip: Int) throws -> Bool {
        try sqlite.transaction {
            try sqlite.execute("DELETE FROM clips WHERE id = ?", [.integer(clip)])
            return sqlite.changes > 0
        }
    }

    /// The clips that sound unlike the rest of their person's, as one of someone else's merged in by mistake would, by
    /// clip: how alike it sounds to the rest, from 0 to 1. A clip is compared with the average of its person's other
    /// clips, each weighed by how long it is, and is odd if `soundAlike` or further from it. The clip that sounds the
    /// most like the rest is taken to be them, and is never odd: of two clips unlike each other, the other one is.
    package static func oddClips(_ prints: [ClipPrint]) -> [Int: Float] {
        var odd: [Int: Float] = [:]
        for theirs in Dictionary(grouping: prints, by: \.person).values where theirs.count > 1 {
            let distances = theirs.map { clip in
                var rest = [Float](repeating: 0, count: clip.print.count)
                for other in theirs where other.id != clip.id {
                    for index in rest.indices { rest[index] += other.print[index] * Float(other.seconds) }
                }
                return (clip, voiceDistance(clip.print, rest))
            }
            let typical = distances.min { ($0.1, $0.0.id) < ($1.1, $1.0.id) }?.0.id
            for (clip, distance) in distances where distance >= soundAlike && clip.id != typical {
                odd[clip.id] = max(0, 1 - distance)
            }
        }
        return odd
    }
}
