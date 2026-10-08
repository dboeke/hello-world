import Foundation

enum ResultOrder: String, CaseIterable, Identifiable {
    case commonality = "Most common"
    case alphabetical = "A–Z"

    var id: String { rawValue }
}

/// What the user has typed. Letters are stored uppercase, as displayed.
struct SearchCriteria: Hashable {
    /// `nil` means any length.
    var length: Int? = 5 {
        didSet { resizePins() }
    }
    /// One entry per position; "" means unknown.
    var pins: [String] = Array(repeating: "", count: 5)
    /// Letters the word must contain. Repeats count: "NN" requires two Ns.
    var include = ""
    /// Letters the word must not contain (except where pinned).
    var exclude = ""
    var minimumCommonality: Commonality = .obscure
    var order: ResultOrder = .commonality

    var isEmpty: Bool {
        pins.allSatisfy(\.isEmpty) && include.isEmpty && exclude.isEmpty
    }

    /// Letters that are both required and excluded (only possible to satisfy via a pin).
    var conflictingLetters: String {
        let excluded = Set(exclude)
        return String(Set(include).filter(excluded.contains).sorted())
    }

    private mutating func resizePins() {
        let count = length ?? 0
        if pins.count > count {
            pins.removeLast(pins.count - count)
        } else if pins.count < count {
            pins += Array(repeating: "", count: count - pins.count)
        }
    }
}

/// A compiled, allocation-free matcher for `SearchCriteria`.
struct WordMatcher: Sendable {
    let length: Int?
    /// Letter (0...25) per position, or `nil` when unpinned.
    let pins: [UInt8?]
    /// (letter, minimum count) pairs.
    let required: [(letter: UInt8, count: Int)]
    /// Indexed by letter.
    let excluded: [Bool]
    let minimumCommonality: Commonality

    init(_ criteria: SearchCriteria) {
        length = criteria.length
        pins = criteria.pins.map { Self.letterIndex($0.first) }

        var counts = [Int](repeating: 0, count: 26)
        for character in criteria.include {
            if let letter = Self.letterIndex(character) { counts[Int(letter)] += 1 }
        }
        required = counts.enumerated()
            .filter { $0.element > 0 }
            .map { (letter: UInt8($0.offset), count: $0.element) }

        var excluded = [Bool](repeating: false, count: 26)
        for character in criteria.exclude {
            if let letter = Self.letterIndex(character) { excluded[Int(letter)] = true }
        }
        self.excluded = excluded
        minimumCommonality = criteria.minimumCommonality
    }

    func matches(_ word: WordEntry) -> Bool {
        if word.commonality < minimumCommonality { return false }

        let letters = word.letters
        if let length, letters.count != length { return false }

        for (position, letter) in letters.enumerated() {
            let pin = position < pins.count ? pins[position] : nil
            if let pin {
                if letter != pin { return false }
            } else if excluded[Int(letter)] {
                return false
            }
        }

        for requirement in required {
            var found = 0
            for letter in letters where letter == requirement.letter { found += 1 }
            if found < requirement.count { return false }
        }
        return true
    }

    private static func letterIndex(_ character: Character?) -> UInt8? {
        guard let ascii = character?.lowercased().first?.asciiValue,
              (97...122).contains(ascii) else { return nil }
        return ascii - 97
    }
}

enum WordSearch {
    static func run(_ criteria: SearchCriteria, in words: [WordEntry]) -> [WordEntry] {
        let matcher = WordMatcher(criteria)
        var results = words.filter(matcher.matches)
        if criteria.order == .alphabetical {
            results.sort { $0.text < $1.text }
        }
        return results
    }
}
