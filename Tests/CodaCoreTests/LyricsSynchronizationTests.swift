import Foundation
import Testing
@testable import CodaCore

@Suite struct LyricsSynchronizationTests {
    private func response(lrc: String?, yrc: String) throws -> LyricResponse {
        var object: [String: Any] = ["yrc": ["lyric": yrc]]
        if let lrc { object["lrc"] = ["lyric": lrc] }
        return try JSONDecoder().decode(LyricResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func lyricClockProjectsSamplesAndFreezesOnPauseOrBuffering() {
        var clock = LyricPlaybackClock()
        let date = Date(timeIntervalSince1970: 1_000)
        clock.reanchor(to: 35.13, rate: 1, at: date)
        #expect(abs(clock.position(at: date.addingTimeInterval(0.75), duration: 273.2) - 35.88) < 0.000001)
        clock.reanchor(to: 42, rate: 0, at: date)
        #expect(clock.position(at: date.addingTimeInterval(30), duration: 273.2) == 42)
        clock.reanchor(to: 272, rate: 1, at: date)
        #expect(clock.position(at: date.addingTimeInterval(10), duration: 273.2) == 273.2)
        clock.reanchor(to: .nan, rate: .nan, at: date)
        #expect(clock.position(at: date.addingTimeInterval(10), duration: 273.2) == 0)
    }

    @Test func parsesTheReportedSongTimingWithoutInventingAnOffset() throws {
        let raw = try response(lrc: "[00:34.69]第一句\n[00:42.58]第二句",
            yrc: "[35130,4020](35130,310,0)第(35440,190,0)一(35630,3520,0)句\n[43070,4380](43070,340,0)第(43410,220,0)二(43630,3820,0)句")
        let karaoke = LyricsParser.parse(raw)
        #expect(karaoke.lines.map(\.time) == [35.13, 43.07])
        #expect(karaoke.lines[0].words?.map(\.start) == [35.13, 35.44, 35.63])
        #expect(karaoke.activeIndex(at: 35.12) == nil)
        #expect(karaoke.activeIndex(at: 35.13) == 0)
        #expect(karaoke.activeIndex(at: 42) == 0)
        #expect(karaoke.activeIndex(at: 43.07) == 1)
        // Both render modes use the same YRC source with their own lead time.
        let lineOnly = LyricsParser.parse(try response(lrc: "[00:34.69]第一句\n[00:42.58]第二句", yrc: ""))
        #expect(lineOnly.lines.map(\.time) == [34.69, 42.58])
        #expect(lineOnly.lines.allSatisfy { $0.words == nil })
    }

    @Test func keepsUpstreamCreditsSortingAndLiteralParentheses() throws {
        let raw = try response(lrc: nil,
            yrc: "{\"t\":-1000,\"c\":[{\"tx\":\"作词：作者\"}]}\n[20000,1000](20000,1000,0)再见\n[10000,2000](10000,1000,0)你好(hello)(11000,1000,0)世界")
        let parsed = LyricsParser.parse(raw)
        #expect(parsed.lines.map(\.time) == [-1, 10, 20])
        #expect(parsed.lines[1].text == "你好(hello)世界")
        #expect(parsed.lines[1].words?.map(\.start) == [10, 11])
        #expect(parsed.lines[0].words == nil)
        #expect(parsed.lines[1].words?.isEmpty == false)
    }

    @Test func preciseOverlapsAndInstrumentalGapsFollowLyricFocusRules() {
        let lines = [TimedLyricLine(id: "a", time: 10, duration: 10, text: "长句"),
                     TimedLyricLine(id: "b", time: 12, duration: 2, text: "短句"),
                     TimedLyricLine(id: "c", time: 30, duration: 2, text: "后句")]
        let overlap = LyricPlaybackTimeline.position(at: 13, in: lines)
        #expect(overlap.activeLyricIDs == ["a", "b"])
        #expect(overlap.highlightedLyricID == "b")
        #expect(overlap.nextTransitionTime == 14)
        let afterShort = LyricPlaybackTimeline.position(at: 15, in: lines)
        #expect(afterShort.highlightedLyricID == "a")
        #expect(afterShort.activeLyricIDs == ["a"])
        let gap = LyricPlaybackTimeline.position(at: 25, in: lines)
        #expect(gap.highlightedLyricID == "b")
        #expect(gap.nextTransitionTime == 30)
    }

    @MainActor @Test func glyphProgressUsesLongToneCurveWithoutEarlyHighlight() {
        let syllables = [LyricSyllable(text: "字", startTime: 35, endTime: 36)]
        let timing = TimedLyricTextBuilder.attributes(from: syllables)[0]
        func progress(_ time: Double) -> Double {
            LyricHighlightRevealProgress.progress(playbackTime: time, timing: timing,
                detectionMode: .character, durationThreshold: 0.95)
        }
        #expect(progress(34.9) == 0)
        #expect(progress(35) == 0)
        #expect(abs(progress(35.5) - 0.86) < 0.000001)
        #expect(abs(progress(36) - 1) < 0.000001)
    }

    @MainActor @Test func scheduledTransitionAndPauseUseTheSameProjectedClock() async throws {
        let parsed = ParsedLyrics(lines: [LyricLine(id: 0, time: 0.03, text: "第一句"),
                                          LyricLine(id: 1, time: 0.3, text: "第二句")])
        let cursor = LyricsCursor()
        cursor.synchronize(lyrics: parsed, at: 0, playing: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(cursor.activeIndex == 0)
        cursor.synchronize(lyrics: parsed, at: 0.1, playing: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(cursor.activeIndex == 0)
        #expect(cursor.playbackTime == 0.1)
    }

    @MainActor @Test func karaokeSettingChangesLeadWithoutReplacingTheAuthoredTimeline() {
        let lyrics = ParsedLyrics(lines: [LyricLine(id: 0, time: 35.13, text: "第一句")])
        let cursor = LyricsCursor()
        cursor.synchronize(lyrics: lyrics, at: 35, playing: false, advanceTime: 0)
        #expect(cursor.activeIndex == nil)
        cursor.synchronize(lyrics: lyrics, at: 35, playing: false, advanceTime: 0.2)
        #expect(cursor.activeIndex == 0)
        #expect(cursor.playbackTime == 35)
        cursor.synchronize(lyrics: lyrics, at: 35, playing: false, advanceTime: 0)
        #expect(cursor.activeIndex == nil)
        #expect(cursor.playbackTime == 35)
    }

    @MainActor @Test func manualTimingMovesLineAndWordClockTogetherAndResets() {
        let lyrics = ParsedLyrics(lines: [LyricLine(id: 0, time: 10, text: "第一句")])
        let cursor = LyricsCursor()
        cursor.synchronize(lyrics: lyrics, at: 9.95, playing: false, timeOffset: 0.1)
        #expect(cursor.activeIndex == 0)
        #expect(abs(cursor.playbackTime - 10.05) < 0.000001)
        cursor.synchronize(lyrics: lyrics, at: 10.05, playing: false, timeOffset: -0.1)
        #expect(cursor.activeIndex == nil)
        #expect(abs(cursor.playbackTime - 9.95) < 0.000001)
        cursor.synchronize(lyrics: lyrics, at: 10.05, playing: false, timeOffset: 0)
        #expect(cursor.activeIndex == 0)
        #expect(cursor.playbackTime == 10.05)
        // Delaying lyrics at the beginning must not clamp away the adjustment.
        cursor.synchronize(lyrics: lyrics, at: 0, playing: false, timeOffset: -0.1)
        #expect(cursor.playbackTime == -0.1)
    }

    @MainActor @Test func seekAndReplacementCancelThePreviousSongTransition() async throws {
        let first = ParsedLyrics(lines: [LyricLine(id: 0, time: 0.05, text: "旧歌")])
        let replacement = ParsedLyrics(lines: [LyricLine(id: 0, time: 10, text: "新歌")])
        let cursor = LyricsCursor()
        cursor.synchronize(lyrics: first, at: 0, playing: true)
        cursor.synchronize(lyrics: replacement, at: 9, playing: false)
        cursor.seekRevision &+= 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(cursor.activeIndex == nil)
        #expect(cursor.playbackTime == 9)
        cursor.synchronize(lyrics: replacement, at: 10, playing: false)
        #expect(cursor.activeIndex == 0)
        cursor.synchronize(lyrics: replacement, at: 0, playing: false)
        #expect(cursor.activeIndex == nil)
    }
}
