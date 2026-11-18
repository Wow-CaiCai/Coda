import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Base text split so each reading sits over the kanji it belongs to.
    /// Nil when there is nothing to annotate.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?
    var timeline: [TimedLyricLine]?

    var synchronizedLines: [TimedLyricLine] {
        timeline ?? lines.map { line in
            TimedLyricLine(id: "coda:\(line.id)", time: line.time,
                timingKind: line.words == nil ? .lineSynchronized : .precise,
                text: line.text, syllables: (line.words ?? []).map {
                    LyricSyllable(text: $0.text, startTime: $0.start, endTime: $0.end)
                })
        }
    }

    var isEmpty: Bool { lines.isEmpty }

    /// The playback timeline handles lyric lookup, including overlapping vocals.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        let native = synchronizedLines
        let position = LyricPlaybackTimeline.position(at: time, in: native)
        return native.firstIndex { $0.id == position.highlightedLyricID }
    }
}

// The timed lyric parser handles parsing and annotation alignment.
// This adapter only retains Coda's API response and Japanese-reading models.
enum LyricsParser {
    static func parseLRC(_ source: String) -> [(time: TimeInterval, text: String)] {
        TimedLyricParser.parseLRC(source).map { ($0.time, $0.text) }
    }

    static func parseYRC(_ source: String) -> [LyricLine] {
        TimedLyricParser.parseYRC(source).enumerated().map { index, line in
            adapt(line, id: index, wordTiming: true)
        }
    }

    private static func adapt(_ line: TimedLyricLine, id: Int, wordTiming: Bool) -> LyricLine {
        LyricLine(id: id, time: line.time, text: line.text,
            translation: line.translation, romaji: line.romanization,
            words: wordTiming && !line.syllables.isEmpty ? line.syllables.map {
                LyricWord(text: $0.text, start: $0.startTime, duration: $0.endTime - $0.startTime)
            } : nil)
    }

    static func parse(_ response: LyricResponse) -> ParsedLyrics {
        let lrc = response.lrc?.lyric ?? ""
        let yrc = response.yrc?.lyric ?? ""
        var native = TimedLyricParser.parse(
            yrc: yrc, lrc: lrc,
            translatedYRC: response.ytlrc?.lyric ?? "",
            translatedLRC: response.tlyric?.lyric ?? "",
            romanizedYRC: response.yromalrc?.lyric ?? "",
            romanizedLRC: response.romalrc?.lyric ?? "")
        var result = ParsedLyrics()
        result.isInstrumental = response.pureMusic == true
        result.contributor = response.lyricUser?.nickname
        result.translationContributor = response.transUser?.nickname
        // Preserve the provider's instrumental designation, which is outside
        // synchronization and is used by track matching and the empty state.
        if native.count <= 10, native.contains(where: { $0.text.contains("纯音乐，请欣赏") }) {
            result.isInstrumental = true
            native.removeAll { $0.text.contains("纯音乐，请欣赏")
                || $0.text.range(of: #"^作(词|曲)\s*[:：]"#, options: .regularExpression) != nil }
        }
        native.removeAll { $0.text.range(of: #"^作(词|曲)\s*[:：]\s*无$"#, options: .regularExpression) != nil }
        result.timeline = native
        result.lines = native.enumerated().map { adapt($0.element, id: $0.offset, wordTiming: true) }
        if RomajiTranscriber.isJapanese(result.lines.map(\.text)) {
            for index in result.lines.indices {
                if result.lines[index].romaji == nil {
                    result.lines[index].romaji = RomajiTranscriber.transcribe(result.lines[index].text)
                }
                result.lines[index].furigana = Furigana.segments(for: result.lines[index].text)
            }
        } else {
            for index in result.lines.indices { result.lines[index].romaji = nil }
        }
        return result
    }
}
