import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: WordStore
    @Environment(\.dismiss) private var dismiss

    private var isLoading: Bool {
        if case .loading = store.phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Dictionary", selection: $store.source) {
                        ForEach(WordSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(isLoading)
                } header: {
                    Text("Word list")
                } footer: {
                    Text("TWL06 is the North American tournament list. SOWPODS (Collins) is used everywhere else and is a superset of TWL06.")
                }

                Section {
                    LabeledContent("Words", value: store.words.count.formatted())
                    if let lastUpdated = store.lastUpdated {
                        LabeledContent("Downloaded", value: lastUpdated.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        Task { await store.load(forceRefresh: true) }
                    } label: {
                        HStack {
                            Text("Download again")
                            if isLoading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoading)
                } footer: {
                    if store.hasFrequencyData {
                        Text("Commonality comes from English word-frequency rankings: Common is roughly the top 10,000 words, Familiar the top 30,000, Uncommon is anything else in the ranking, and Obscure words don't appear in it at all.")
                    } else {
                        Text("Word-frequency data couldn't be downloaded, so commonality isn't available. Tap Download again to retry.")
                    }
                }
            }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Shows the system dictionary's definition of a word.
struct DefinitionView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
