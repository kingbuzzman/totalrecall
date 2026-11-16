import Foundation

extension SpeakerDatabase {
    /// Folds together those who are surely one person taken for two, as someone is told apart from their first few
    /// prints, and an earlier call may have heard them differently: someone with no name into whoever sounds the most
    /// like them, if within `samePerson` and both have been heard for at least `samePersonPrints`; and two given the
    /// same name, if they sound alike at all. Two with different names are never folded together. Returns who was
    /// folded into whom, in turn.
    func unify() throws -> [(merged: Person, into: Person)] {
        var unified: [(merged: Person, into: Person)] = []
        while true {
            let people = try people()
            let voices = Dictionary(grouping: try voices(), by: \.person)
            let prints = voices.mapValues { $0.reduce(0) { $0 + $1.prints } }
            func distance(_ one: Person, _ other: Person) -> Float {
                (voices[one.id] ?? []).flatMap { voice in
                    (voices[other.id] ?? []).map { voiceDistance(voice.print, $0.print) }
                }
                .min() ?? .infinity
            }
            let pairs = people.flatMap { merged in
                people.compactMap { kept -> (Person, Person, Float)? in
                    guard merged.id != kept.id else { return nil }
                    let (distance, mergedPrints, keptPrints) = (
                        distance(merged, kept), prints[merged.id] ?? 0, prints[kept.id] ?? 0
                    )
                    if let name = merged.name {
                        guard name == kept.name, mergedPrints <= keptPrints, distance < SpeakerIdentifier.soundAlike
                        else { return nil }
                    } else {
                        guard distance < Self.samePerson, min(mergedPrints, keptPrints) >= Self.samePersonPrints,
                            kept.name != nil || mergedPrints <= keptPrints
                        else { return nil }
                    }
                    return (merged, kept, distance)
                }
            }
            guard let (merged, kept, _) = pairs.min(by: { $0.2 < $1.2 }) else { return unified }
            guard try merge(merged.id, into: kept.id) else { return unified }
            unified.append((merged, kept))
        }
    }
}

extension SpeakerDatabase {
    /// The voices that sound unlike the rest of their person's, as one merged in by mistake would, by voice: how alike
    /// it sounds to the others, from 0 to 1. A voice is compared with the average of its person's other voices, each
    /// weighed by how long it was heard, and is odd if `soundAlike` or further from it. Of two voices that sound unlike
    /// each other, or of a person whose voices all do, the one heard the most is taken to be them, and is not odd.
    package static func oddVoices(_ voices: [Voice]) -> [Int: Float] {
        var odd: [Int: Float] = [:]
        for theirs in Dictionary(grouping: voices, by: \.person).values where theirs.count > 1 {
            let distances = theirs.map { voice in
                let others = theirs.filter { $0.id != voice.id }
                var center = [Float](repeating: 0, count: voice.print.count)
                for other in others {
                    for index in center.indices { center[index] += other.print[index] * Float(max(other.prints, 1)) }
                }
                return (voice, voiceDistance(voice.print, center))
            }
            let mostHeard = theirs.max { ($0.prints, $1.id) < ($1.prints, $0.id) }?.id
            for (voice, distance) in distances where distance >= soundAlike && voice.id != mostHeard {
                odd[voice.id] = max(0, 1 - distance)
            }
        }
        return odd
    }
}
