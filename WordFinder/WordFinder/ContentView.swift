import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: WordStore
    @State private var criteria = SearchCriteria()
    @State private var results: [WordEntry] = []
    @State private var isSearching = false
    @State private var showingSettings = false
    @State private var definedWord: DefinedWord?

    private let displayLimit = 2_000

    private struct SearchKey: Hashable {
        let criteria: SearchCriteria
        let version: Int
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                criteriaSection
                resultsSection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Word Finder")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { clear() }
                        .disabled(criteria.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Dictionary", systemImage: "books.vertical")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(item: $definedWord) { word in
                DefinitionView(term: word.text)
                    .ignoresSafeArea()
            }
            .task(id: SearchKey(criteria: criteria, version: store.version)) {
                await search()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        switch store.phase {
        case .loading(let message):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(message).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await store.load(forceRefresh: true) } }
                }
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private var criteriaSection: some View {
        Section {
            Picker("Word length", selection: $criteria.length) {
                Text("Any").tag(Int?.none)
                ForEach(2...15, id: \.self) { length in
                    Text("\(length) letters").tag(Int?.some(length))
                }
            }

            if criteria.length != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Known positions")
                        .font(.subheadline)
                    PinRow(pins: $criteria.pins)
                }
                .padding(.vertical, 4)
            }

            LetterField(
                title: "Must include",
                prompt: "e.g. ENNR",
                text: $criteria.include,
                allowRepeats: true
            )
            LetterField(
                title: "Must not include",
                prompt: "e.g. STOP",
                text: $criteria.exclude,
                allowRepeats: false
            )

            Picker("Commonality", selection: $criteria.minimumCommonality) {
                ForEach(Commonality.allCases) { level in
                    Text(level.filterLabel).tag(level)
                }
            }
            Picker("Sort by", selection: $criteria.order) {
                ForEach(ResultOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        } header: {
            Text("Criteria")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned letters count toward “Must include”. Repeat a letter (NN) to require it twice.")
                if !criteria.conflictingLetters.isEmpty {
                    Text("\(criteria.conflictingLetters) is both required and excluded, so it can only appear where pinned.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var resultsSection: some View {
        Section {
            if results.isEmpty && !isSearching && !store.words.isEmpty {
                Text("No matching words.")
                    .foregroundStyle(.secondary)
            }
            ForEach(results.prefix(displayLimit)) { word in
                Button {
                    definedWord = DefinedWord(text: word.text)
                } label: {
                    WordRow(word: word, showCommonality: store.hasFrequencyData)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = word.text.uppercased()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            if results.count > displayLimit {
                Text("Showing the first \(displayLimit.formatted()) — add more criteria to narrow it down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(store.words.isEmpty ? "Results" : "\(results.count.formatted()) matches")
                if isSearching { ProgressView().controlSize(.mini) }
            }
        }
    }

    // MARK: Actions

    private func search() async {
        let words = store.words
        let criteria = criteria
        isSearching = true
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) {
            WordSearch.run(criteria, in: words)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    private func clear() {
        var cleared = SearchCriteria()
        cleared.length = criteria.length
        cleared.minimumCommonality = criteria.minimumCommonality
        cleared.order = criteria.order
        criteria = cleared
    }
}

private struct DefinedWord: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - Rows and inputs

struct WordRow: View {
    let word: WordEntry
    let showCommonality: Bool

    var body: some View {
        HStack {
            Text(word.text.uppercased())
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if showCommonality {
                CommonalityBadge(level: word.commonality)
            }
        }
    }
}

struct CommonalityBadge: View {
    let level: Commonality

    var body: some View {
        Text(level.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch level {
        case .common: .green
        case .familiar: .blue
        case .uncommon: .orange
        case .obscure: .gray
        }
    }
}

/// A text field that only accepts letters and shows them uppercase.
struct LetterField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let allowRepeats: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: sanitized, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
        }
    }

    private var sanitized: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                var seen = Set<Character>()
                text = String(newValue.uppercased().filter { character in
                    guard character.isASCII, character.isLetter else { return false }
                    return allowRepeats || seen.insert(character).inserted
                })
            }
        )
    }
}

/// One box per letter position; typing a letter moves to the next box.
struct PinRow: View {
    @Binding var pins: [String]
    @FocusState private var focused: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pins.indices), id: \.self) { index in
                    VStack(spacing: 2) {
                        TextField("", text: binding(for: index))
                            .font(.title3.monospaced().bold())
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused($focused, equals: index)
                            .frame(width: 36, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(index >= pins.count || pins[index].isEmpty ? Color.clear : Color.accentColor.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(focused == index ? Color.accentColor : Color.secondary.opacity(0.4),
                                                  lineWidth: focused == index ? 2 : 1)
                            )
                        Text("\(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < pins.count ? pins[index] : "" },
            set: { newValue in
                guard index < pins.count else { return }
                let letter = newValue.uppercased().last(where: { $0.isASCII && $0.isLetter })
                pins[index] = letter.map(String.init) ?? ""
                if letter != nil {
                    focused = index + 1 < pins.count ? index + 1 : nil
                }
            }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(WordStore())
}
