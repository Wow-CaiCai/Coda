import Foundation

/// Metadata belongs to the recording found in that provider's catalog. Missing
/// fields remain missing: the current track's album must never fill a search hit.
struct LyricsCandidate {
    let source: LyricsSource
    let id: String
    let title: String
    let artists: [String]
    let album: String?
    let duration: TimeInterval?
    let response: LyricResponse
}

struct LyricsSelection {
    let source: LyricsSource
    let response: LyricResponse
}

enum LyricsMatching {
    static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    static func artists(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "/、,，;&＆"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Identity is a gate, rather than a bonus that word timing could outweigh.
    /// Keep version labels (Live, remix, accompaniment, etc.) in title equality.
    static func metadataScore(title: String, artists: [String], album: String?,
                              duration: TimeInterval?, track: Track) -> Double? {
        let titleKey = normalized(title)
        guard !titleKey.isEmpty, titleKey == normalized(track.name) else { return nil }
        let expected = track.artists.map { normalized($0.name) }.filter { !$0.isEmpty }
        // Preserve band names containing '&' or '/', while still accepting
        // providers that return several performers in one string.
        let found = Set(artists.flatMap { artist -> [String] in
            let key = normalized(artist)
            return expected.contains(key) ? [key] : self.artists(in: artist).map(normalized)
        }.filter { !$0.isEmpty })
        guard let primary = expected.first, found.contains(primary) else { return nil }
        let overlap = expected.filter { found.contains($0) }.count
        let artistScore = 30 * Double(overlap) / Double(expected.count)
        // Extra artists can indicate a different duet or cover recording.
        let extraPenalty = Double(found.subtracting(Set(expected)).count) * 4
        var score = 40 + artistScore - min(8, extraPenalty)
        let albumKey = album.map(normalized) ?? ""
        let expectedAlbum = normalized(track.album.name)
        if !albumKey.isEmpty, !expectedAlbum.isEmpty {
            score += albumKey == expectedAlbum ? 12 : -6
        }
        if let duration, duration.isFinite, duration > 0, track.duration > 0 {
            let delta = abs(duration - track.duration)
            // Short songs need a tighter bound; twelve seconds is the ceiling.
            guard delta <= min(12, max(3, track.duration * 0.04)) else { return nil }
            score += max(0, 18 - delta * 2)
        }
        return score
    }

    /// Score real word coverage rather than trusting a provider's format label.
    static func qualityScore(_ response: LyricResponse, duration: TimeInterval) -> Double? {
        let parsed = LyricsParser.parse(response)
        if parsed.isInstrumental { return 0 }
        let lines = parsed.lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.range(of: #"^(作词|作曲|编曲|制作人|混音|录音|词|曲)\s*[:：]"#,
                                               options: .regularExpression) == nil
        }
        guard !lines.isEmpty else { return nil }
        var previous: TimeInterval = -1
        for line in lines {
            guard line.time.isFinite, line.time >= 0, line.time >= previous,
                  duration <= 0 || line.time <= duration + 10 else { return nil }
            previous = line.time
        }
        let timed = lines.filter { line in
            guard let words = line.words, words.count > 1 else { return false }
            var end = line.time
            for word in words {
                guard word.start.isFinite, word.duration.isFinite, word.duration > 0,
                      word.start >= end - 0.05, duration <= 0 || word.end <= duration + 10 else { return false }
                end = word.end
            }
            return normalized(words.map(\.text).joined()) == normalized(line.text)
        }.count
        let wordBonus = 24 * Double(timed) / Double(lines.count)
        let translated = lines.filter { $0.translation?.isEmpty == false }.count
        return wordBonus + 2 * Double(translated) / Double(lines.count)
    }

    static func score(_ candidate: LyricsCandidate, for track: Track) -> Double? {
        guard candidate.source != .automatic,
              let quality = qualityScore(candidate.response, duration: track.duration) else { return nil }
        if isNativeQishui(candidate, for: track) { return 100 + quality }
        guard let metadata = metadataScore(title: candidate.title, artists: candidate.artists, album: candidate.album,
                                           duration: candidate.duration, track: track) else { return nil }
        return metadata + quality
    }

    private static func isNativeQishui(_ candidate: LyricsCandidate, for track: Track) -> Bool {
        candidate.source == .qishui && !candidate.id.isEmpty && candidate.id == track.platformSong?.qishui?.trackID
    }

    static func best(_ candidates: [LyricsCandidate], for track: Track) -> LyricsSelection? {
        // The original catalog's instrumental designation is authoritative.
        if let original = candidates.first(where: {
            ($0.source == .netease || isNativeQishui($0, for: track))
                && LyricsParser.parse($0.response).isInstrumental && score($0, for: track) != nil
        }) {
            return LyricsSelection(source: original.source, response: original.response)
        }
        let ranked = candidates.compactMap { candidate -> (LyricsCandidate, Double)? in
            guard let score = score(candidate, for: track) else { return nil }
            return (candidate, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let order = LyricsSource.providers
            let left = order.firstIndex(of: lhs.0.source) ?? order.count
            let right = order.firstIndex(of: rhs.0.source) ?? order.count
            if left != right { return left < right }
            return lhs.0.id < rhs.0.id
        }
        return ranked.first.map { LyricsSelection(source: $0.0.source, response: $0.0.response) }
    }
}

/// Only successful automatic matches are cached, by full track metadata. Manual
/// selection always makes a fresh request; errors never poison later retries.
actor LyricsSelectionCache {
    static let shared = LyricsSelectionCache()
    private var entries: [Track: (date: Date, selection: LyricsSelection)] = [:]

    func value(for track: Track) -> LyricsSelection? {
        guard let entry = entries[track], Date().timeIntervalSince(entry.date) < 900 else {
            entries[track] = nil
            return nil
        }
        return entry.selection
    }

    func store(_ selection: LyricsSelection, for track: Track) {
        if entries.count >= 40, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries[oldest] = nil
        }
        entries[track] = (Date(), selection)
    }
}
