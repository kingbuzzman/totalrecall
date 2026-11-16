import Accelerate

/// Sorts voice prints into groups of one person each, by average linkage: the two groups closest on average, print to
/// print, become one, for as long as some two are within `within`. Prints are of length 1, so how far a group is from a
/// print, or another group, on average, comes from the sum of its prints alone. In O(n²) time and O(n) memory, by
/// nearest-neighbor chains (Murtagh, 1983): an hour's prints take a moment, where comparing every two at every step
/// would take minutes.
enum VoiceGroups {
    /// The group of each print, numbered from 0 in the order of their first prints.
    static func group(_ prints: [[Float]], within limit: Float) -> [Int] {
        var groups = prints.indices.map { Group(sum: prints[$0], members: [$0]) }
        var open = Set(prints.indices)
        var chain: [Int] = []
        while open.count > 1 {
            if chain.isEmpty { chain.append(open.min()!) }
            let last = chain[chain.count - 1]
            let previous = chain.count > 1 ? chain[chain.count - 2] : nil
            var (nearest, distance) = (
                previous ?? -1, previous.map { groups[last].distance(to: groups[$0]) } ?? .infinity
            )
            for other in open where other != last && other != previous {
                let candidate = groups[last].distance(to: groups[other])
                if candidate < distance { (nearest, distance) = (other, candidate) }
            }
            guard nearest == previous else {
                chain.append(nearest)
                continue
            }
            chain.removeLast(2)
            if distance <= limit {
                groups[nearest].take(groups[last])
                groups[last].members = []
                open.remove(last)
            } else {
                // Each the other's nearest, and too far apart: average linkage only moves groups further from both.
                open.remove(last)
                open.remove(nearest)
            }
        }
        var numbers = [Int](repeating: 0, count: prints.count)
        for (number, group) in groups.enumerated() {
            for member in group.members { numbers[member] = number }
        }
        return numberedInOrder(numbers)
    }

    /// Groups of fewer than `fewest` prints, too little of anyone to be sure of, join the nearest larger one; with
    /// none larger, the largest is kept. Groups are then numbered again, in the order of their first prints.
    static func fold(_ groups: [Int], of prints: [[Float]], fewest: Int) -> [Int] {
        let sizes = Dictionary(groups.map { ($0, 1) }, uniquingKeysWith: +)
        var large = sizes.filter { $0.value >= fewest }.map(\.key)
        if large.isEmpty, let largest = sizes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            large = [largest]
        }
        let sums = Dictionary(
            uniqueKeysWithValues: large.map { group in
                (group, sum(of: groups.indices.filter { groups[$0] == group }.map { prints[$0] }))
            }
        )
        let folded = groups.indices.map { index in
            sums[groups[index]] != nil ? groups[index] : nearest(to: prints[index], among: sums)!
        }
        return numberedInOrder(folded)
    }

    /// Which of these groups, by the sum of their prints, `print` is nearest on average; nil with none.
    static func nearest(to print: [Float], among sums: [Int: (sum: [Float], count: Int)]) -> Int? {
        sums.min { first, second in
            let (a, b) = (
                vDSP.dot(print, first.value.sum) / Float(first.value.count),
                vDSP.dot(print, second.value.sum) / Float(second.value.count)
            )
            return a != b ? a > b : first.key < second.key
        }?.key
    }

    static func sum(of prints: [[Float]]) -> (sum: [Float], count: Int) {
        var sum = [Float](repeating: 0, count: prints.first?.count ?? 0)
        for print in prints { vDSP.add(sum, print, result: &sum) }
        return (sum, prints.count)
    }

    /// The same groups, numbered from 0 in the order of their first members.
    static func numberedInOrder(_ groups: [Int]) -> [Int] {
        var numbers: [Int: Int] = [:]
        return groups.map { group in
            if let number = numbers[group] { return number }
            numbers[group] = numbers.count
            return numbers.count - 1
        }
    }

    private struct Group {
        var sum: [Float]
        var members: [Int]

        /// 1 less the average cosine of a print of one with a print of the other.
        func distance(to other: Group) -> Float {
            1 - vDSP.dot(sum, other.sum) / Float(members.count * other.members.count)
        }

        mutating func take(_ other: Group) {
            vDSP.add(sum, other.sum, result: &sum)
            members += other.members
        }
    }
}
