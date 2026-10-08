# Word Finder (iOS)

A SwiftUI app for finding Scrabble words from partial information.

## What it does

On first launch it downloads a Scrabble dictionary and an English word-frequency list,
builds an index, and caches it on the device (Application Support), so later launches are instant
and work offline.

Search criteria:

- **Word length**: 2–15 letters, or any length.
- **Known positions**: one box per letter. Type a letter to pin it to that position (for example, a 3rd letter of A).
- **Must include**: letters that must appear anywhere in the word. Repeats count, so `ENNR` needs two Ns.
  Pinned letters count toward this.
- **Must not include**: letters that can't appear, except in a position you pinned.
- **Commonality**: show all words, hide obscure ones, or show only familiar or common words.
- **Sort**: most common first, or A–Z.

Tap a result to open its definition in the iOS dictionary. Long-press to copy it.

Example: length 7, position 3 = `A`, must include `ENNR`.

## Dictionaries

Pick one under the book icon:

| Option | Notes |
| --- | --- |
| TWL06 | North American tournament list (default) |
| SOWPODS / Collins | International list, a superset of TWL06 |
| ENABLE | Public-domain list, similar to Words With Friends |

Commonality comes from Peter Norvig's Google Web Trillion Word Corpus counts (`count_1w.txt`), with
the OpenSubtitles 50k list as a fallback. Rank ≤ 10,000 is **Common**, ≤ 30,000 is **Familiar**,
any other ranked word is **Uncommon**, and unranked words are **Obscure**.

## Building

Requires Xcode 16 or later and iOS 17 or later.

1. Open `WordFinder.xcodeproj`.
2. Select the **WordFinder** target, go to *Signing & Capabilities*, and choose your team.
   If `com.boeke.WordFinder` is already taken, change the bundle identifier.
3. Run on a simulator or on your iPhone.

The project uses a synchronized folder, so any Swift file added to `WordFinder/` is compiled automatically.

## Code layout

- `WordStore.swift`: dictionary sources, download, parsing, frequency ranking, on-disk cache.
- `WordSearch.swift`: search criteria and the matcher.
- `ContentView.swift`: main search screen.
- `SettingsView.swift`: dictionary picker and refresh, plus the system definition view.
