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
