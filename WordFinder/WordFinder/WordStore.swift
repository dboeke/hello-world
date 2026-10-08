import Foundation

/// A Scrabble dictionary the app can download.
enum WordSource: String, CaseIterable, Identifiable {
    case twl06
    case sowpods
    case enable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twl06: "TWL06 (North America)"
        case .sowpods: "SOWPODS / Collins (International)"
        case .enable: "ENABLE (Words With Friends style)"
        }
    }

    /// Mirrors are tried in order until one succeeds.
    var urls: [URL] {
        let strings: [String]
        switch self {
        case .twl06:
            strings = [
                "https://raw.githubusercontent.com/cviebrock/wordlists/master/TWL06.txt",
                "https://www.wordgamedictionary.com/twl06/download/twl06.txt",
            ]
        case .sowpods:
            strings = [
                "https://raw.githubusercontent.com/jesstess/Scrabble/master/scrabble/sowpods.txt",
                "https://www.wordgamedictionary.com/sowpods/download/sowpods.txt",
            ]
        case .enable:
            strings = [
                "https://raw.githubusercontent.com/dolph/dictionary/master/enable1.txt",
                "https://norvig.com/ngrams/enable1.txt",
            ]
        }
        return strings.compactMap(URL.init(string:))
    }
}

/// English word-frequency lists, sorted most common first. Only the line order is used.
enum FrequencySource {
    static let urls: [URL] = [
        // Peter Norvig's 333k most frequent words from the Google Web Trillion Word Corpus.
        "https://norvig.com/ngrams/count_1w.txt",
        // 50k most frequent words from OpenSubtitles (2018).
        "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
    ].compactMap(URL.init(string:))
}

/// How common a word is in everyday English, derived from its frequency rank.
enum Commonality: Int, CaseIterable, Comparable, Identifiable {
    case obscure, uncommon, familiar, common

    var id: Int { rawValue }

    init(rank: Int32) {
        switch rank {
        case ...10_000: self = .common
        case ...30_000: self = .familiar
        case Int32.max: self = .obscure
        default: self = .uncommon
        }
    }

    static func < (lhs: Commonality, rhs: Commonality) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .obscure: "Obscure"
        case .uncommon: "Uncommon"
        case .familiar: "Familiar"
        case .common: "Common"
        }
    }

    /// Label used when this level is the minimum in a filter.
    var filterLabel: String {
        switch self {
        case .obscure: "All words"
        case .uncommon: "Hide obscure"
        case .familiar: "Familiar & common"
        case .common: "Common only"
        }
    }
}

struct WordEntry: Identifiable, Hashable, Sendable {
    /// Lowercase word.
    let text: String
    /// Letters as 0...25.
    let letters: [UInt8]
    /// 1 is the most common word in English; `Int32.max` means not in the frequency list.
    let rank: Int32

    var id: String { text }
    var commonality: Commonality { Commonality(rank: rank) }

    init(text: String, rank: Int32) {
        self.text = text
        self.letters = text.utf8.map { $0 &- 97 }
        self.rank = rank
    }
}

@MainActor
final class WordStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    private static let sourceKey = "wordSource"

    @Published private(set) var phase: Phase = .idle
    /// All words, sorted by commonality (most common first), then alphabetically.
    @Published private(set) var words: [WordEntry] = []
    /// Bumped every time `words` is replaced, so views can re-run searches.
    @Published private(set) var version = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasFrequencyData = true

    @Published var source: WordSource {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            Task { await load() }
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sourceKey)
        source = saved.flatMap(WordSource.init(rawValue:)) ?? .twl06
    }

    /// Loads the current dictionary from the on-disk cache, downloading it if needed (or if `forceRefresh`).
    func load(forceRefresh: Bool = false) async {
        let source = self.source

        if !forceRefresh {
            phase = .loading("Loading \(source.displayName)…")
            if let cached = await Task.detached(priority: .userInitiated, operation: { WordCache.load(source) }).value,
               !cached.words.isEmpty {
                guard source == self.source else { return }
                apply(cached.words, date: cached.date)
                return
            }
        }

        do {
            phase = .loading("Downloading \(source.displayName)…")
            let wordData = try await Downloader.fetch(source.urls)

            phase = .loading("Downloading word frequencies…")
            let frequencyData = try? await Downloader.fetch(FrequencySource.urls)

            phase = .loading("Building word index…")
            let entries = await Task.detached(priority: .userInitiated) {
                let built = WordIndexBuilder.build(wordData: wordData, frequencyData: frequencyData)
                if !built.isEmpty { try? WordCache.save(built, for: source) }
                return built
            }.value

            guard source == self.source else { return }
            guard !entries.isEmpty else {
                phase = .failed("The downloaded word list was empty.")
                return
            }
            apply(entries, date: .now)
        } catch {
            guard source == self.source else { return }
            phase = .failed("Couldn't download the word list: \(error.localizedDescription)")
        }
    }

    private func apply(_ entries: [WordEntry], date: Date?) {
        words = entries
        lastUpdated = date
        hasFrequencyData = entries.contains { $0.rank != Int32.max }
        version += 1
        phase = .ready
    }
}

enum Downloader {
    struct BadResponse: LocalizedError {
        let url: URL
        let status: Int
        var errorDescription: String? { "\(url.host() ?? url.absoluteString) returned HTTP \(status)" }
    }

    /// Returns the body of the first URL that answers with a non-empty 2xx response.
    static func fetch(_ urls: [URL]) async throws -> Data {
        var lastError: Error = URLError(.badURL)
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status), !data.isEmpty else {
                    throw BadResponse(url: url, status: status)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

enum WordIndexBuilder {
    /// Parses a one-word-per-line dictionary and a most-common-first frequency list
    /// (one `word [count]` per line) into entries sorted by commonality, then alphabetically.
    static func build(wordData: Data, frequencyData: Data?) -> [WordEntry] {
        var ranks: [String: Int32] = [:]
        if let frequencyData {
            var rank: Int32 = 0
            forEachFirstToken(in: frequencyData) { word in
                rank += 1
                if ranks[word] == nil { ranks[word] = rank }
            }
        }

        var seen = Set<String>()
        var entries: [WordEntry] = []
        entries.reserveCapacity(300_000)
        forEachFirstToken(in: wordData) { word in
            guard seen.insert(word).inserted else { return }
            entries.append(WordEntry(text: word, rank: ranks[word] ?? Int32.max))
        }
        entries.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.text < $1.text }
        return entries
    }

    /// Calls `body` with the first whitespace-delimited token of each line, lowercased,
    /// skipping tokens that contain anything other than the letters a–z.
    static func forEachFirstToken(in data: Data, _ body: (String) -> Void) {
        var token: [UInt8] = []
        var inFirstToken = true
        var valid = true

        for byte in data {
            switch byte {
            case UInt8(ascii: "\n"):
                if valid, !token.isEmpty { body(String(decoding: token, as: UTF8.self)) }
                token.removeAll(keepingCapacity: true)
                inFirstToken = true
                valid = true
            case UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: " "), UInt8(ascii: "\t"):
                if !token.isEmpty { inFirstToken = false }
            default:
                guard inFirstToken else { continue }
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"): token.append(byte)
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): token.append(byte + 32)
                default: valid = false
                }
            }
        }
        if valid, !token.isEmpty { body(String(decoding: token, as: UTF8.self)) }
    }
}

/// Stores each processed dictionary as `word<TAB>rank` lines in Application Support.
enum WordCache {
    private static func fileURL(for source: WordSource) throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WordFinder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(source.rawValue)-v1.tsv")
    }

    static func save(_ entries: [WordEntry], for source: WordSource) throws {
        var text = ""
        text.reserveCapacity(entries.count * 16)
        for entry in entries {
            text += entry.text
            text += "\t"
            text += String(entry.rank)
            text += "\n"
        }
        try Data(text.utf8).write(to: fileURL(for: source), options: .atomic)
    }

    static func load(_ source: WordSource) -> (words: [WordEntry], date: Date?)? {
        guard let url = try? fileURL(for: source),
              let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path()))?[.modificationDate] as? Date

        var entries: [WordEntry] = []
        entries.reserveCapacity(300_000)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"),
                  let rank = Int32(line[line.index(after: tab)...]) else { continue }
            entries.append(WordEntry(text: String(line[..<tab]), rank: rank))
        }
        return (entries, date)
    }
}
