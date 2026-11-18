// Adapted from WXRIW/Lyricify-Lyrics-Helper (Apache-2.0).
// Swift port of QQMusic/LRCLIB/Kugou providers and KRC decoding; see ThirdPartyNotices.
import Foundation
import zlib

enum LyricsSource: String, CaseIterable, Identifiable {
    case automatic, netease, qqMusic, kugou, qishui, lrclib
    static let providers: [Self] = [.netease, .qqMusic, .kugou, .qishui, .lrclib]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动优选"
        case .netease: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .qishui: return "汽水音乐"
        case .lrclib: return "LRCLIB"
        }
    }
    static func saved(for trackID: Int, defaults: UserDefaults = .standard) -> Self {
        let sources = defaults.dictionary(forKey: "lyrics.trackSources") as? [String: String] ?? [:]
        return sources[String(trackID)].flatMap(Self.init(rawValue:)) ?? .automatic
    }
    func save(for trackID: Int, defaults: UserDefaults = .standard) {
        var sources = defaults.dictionary(forKey: "lyrics.trackSources") as? [String: String] ?? [:]
        sources[String(trackID)] = self == .automatic ? nil : rawValue
        defaults.set(sources, forKey: "lyrics.trackSources")
    }
}

enum AlternativeLyricsAPI {
    enum Failure: LocalizedError {
        case noMatch, invalidResponse
        var errorDescription: String? {
            switch self {
            case .noMatch: return "此来源没有找到匹配的同步歌词，请尝试其他来源。"
            case .invalidResponse: return "歌词来源暂时不可用，请稍后重试或切换来源。"
            }
        }
    }

    static func resolve(track: Track, source: LyricsSource,
                        onUpdate: (@Sendable (LyricsSelection) async -> Void)? = nil) async throws -> LyricsSelection {
        try Task.checkCancellation()
        if source == .automatic {
            if let cached = await LyricsSelectionCache.shared.value(for: track) { return cached }
            let selection = try await automatic(track: track, onUpdate: onUpdate) { source in
                try await candidates(track: track, source: source)
            }
            try Task.checkCancellation()
            await LyricsSelectionCache.shared.store(selection, for: track)
            return selection
        }
        let results = try await candidates(track: track, source: source)
        try Task.checkCancellation()
        guard let selection = LyricsMatching.best(results, for: track) else { throw Failure.noMatch }
        return selection
    }

    /// Each provider runs independently with a deadline. Arrival order does not
    /// affect ranking, and a missing or broken provider cannot discard good hits.
    static func automatic(track: Track, timeout: TimeInterval = 12,
                          onUpdate: (@Sendable (LyricsSelection) async -> Void)? = nil,
                          loader: @escaping @Sendable (LyricsSource) async throws -> [LyricsCandidate]) async throws -> LyricsSelection {
        let results = await withTaskGroup(of: [LyricsCandidate].self) { group in
            for source in LyricsSource.providers {
                group.addTask {
                    await withTaskGroup(of: [LyricsCandidate].self) { race in
                        race.addTask { (try? await loader(source)) ?? [] }
                        race.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                            return []
                        }
                        let first = await race.next() ?? []
                        race.cancelAll()
                        return first
                    }
                }
            }
            var all: [LyricsCandidate] = []
            var previousSource: LyricsSource?
            for await candidates in group {
                all.append(contentsOf: candidates)
                if !Task.isCancelled, let best = LyricsMatching.best(all, for: track), best.source != previousSource {
                    previousSource = best.source
                    await onUpdate?(best)
                }
            }
            return all
        }
        try Task.checkCancellation()
        guard let selection = LyricsMatching.best(results, for: track) else { throw Failure.noMatch }
        return selection
    }

    private static func candidates(track: Track, source: LyricsSource) async throws -> [LyricsCandidate] {
        try Task.checkCancellation()
        switch source {
        case .automatic: return []
        case .netease:
            let response = try await NeteaseAPI.lyric(id: track.id)
            return [LyricsCandidate(source: .netease, id: String(track.id), title: track.name,
                artists: track.artists.map(\.name), album: track.album.name, duration: track.duration, response: response)]
        case .qqMusic: return try await qqMusic(track)
        case .kugou: return try await kugou(track)
        case .qishui: return try await qishui(track)
        case .lrclib: return try await lrclib(track)
        }
    }

    private static func qishui(_ track: Track) async throws -> [LyricsCandidate] {
        let api = await QishuiMusicAPI.shared
        if let id = track.platformSong?.qishui?.trackID, !id.isEmpty {
            let response = try await api.lyric(trackID: id)
            return [LyricsCandidate(source: .qishui, id: id, title: track.name,
                artists: track.artists.map(\.name), album: track.album.name, duration: track.duration, response: response)]
        }

        let keyword = ([track.name] + track.artists.prefix(1).map(\.name)).joined(separator: " ")
        let page = try await api.search(keyword: keyword, playlists: false, limit: 15, offset: 0)
        let matches = page.songs.compactMap { song -> (id: String, song: ProviderSong, artists: [String], score: Double)? in
            let artists = [song.artists]
            guard let id = song.qishui?.trackID,
                  let score = LyricsMatching.metadataScore(title: song.name, artists: artists,
                    album: song.album, duration: song.duration, track: track) else { return nil }
            return (id, song, artists, score)
        }.sorted { $0.score > $1.score }
        var results: [LyricsCandidate] = []
        for match in matches.prefix(3) {
            try Task.checkCancellation()
            if let response = try? await api.lyric(trackID: match.id) {
                results.append(LyricsCandidate(source: .qishui, id: match.id, title: match.song.name,
                    artists: match.artists, album: match.song.album, duration: match.song.duration, response: response))
            }
        }
        return results
    }

    private static func request(_ base: String, query: [String: String] = [:], body: [String: Any]? = nil,
                                referer: String? = nil) async throws -> [String: Any] {
        var components = URLComponents(string: base)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 18)
        // Third-party requests never share the music account's cookies.
        request.httpShouldHandleCookies = false
        request.setValue("Coda/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 404 { throw Failure.noMatch }
        guard (200..<300).contains(http.statusCode) else { throw Failure.invalidResponse }
        let json = try JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any] { return object }
        if let list = json as? [[String: Any]] { return ["results": list] }
        throw Failure.invalidResponse
    }

    static func response(lrc: String, translation: String? = nil, yrc: String? = nil) throws -> LyricResponse {
        guard !LyricsParser.parseLRC(lrc).isEmpty else { throw Failure.noMatch }
        return LyricResponse(lrc: .init(lyric: lrc), tlyric: translation.map { .init(lyric: $0) },
                             romalrc: nil, yrc: yrc.map { .init(lyric: $0) }, ytlrc: nil, yromalrc: nil,
                             lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
    }

    static func matchScore(title: String, artist: String, duration: Double, track: Track) -> Double? {
        guard LyricsMatching.metadataScore(title: title, artists: [artist],
                                          album: nil, duration: duration, track: track) != nil else { return nil }
        return abs(duration - track.duration)
    }

    private static func makeCandidate(source: LyricsSource, id: String, title: String, artists: [String],
                                      album: String?, duration: Double?, response: LyricResponse, track: Track) -> LyricsCandidate? {
        let candidate = LyricsCandidate(source: source, id: id, title: title, artists: artists,
                                        album: album, duration: duration, response: response)
        return LyricsMatching.score(candidate, for: track) == nil ? nil : candidate
    }

    private static func lrclib(_ track: Track) async throws -> [LyricsCandidate] {
        // Search exposes album and duration for every recording. The exact get
        // endpoint can hide a better album match behind its single result.
        let search = try await request("https://lrclib.net/api/search", query: ["track_name": track.name,
            "artist_name": track.artists.first?.name ?? track.artistNames])
        return (search["results"] as? [[String: Any]] ?? []).compactMap { item in
            let instrumental = item["instrumental"] as? Bool == true
            guard let response = try? response(lrc: instrumental ? "[00:00.00]纯音乐，请欣赏" : item["syncedLyrics"] as? String ?? "") else { return nil }
            return makeCandidate(source: .lrclib, id: String(describing: item["id"] ?? ""),
                title: item["trackName"] as? String ?? "", artists: [item["artistName"] as? String ?? ""],
                album: item["albumName"] as? String, duration: (item["duration"] as? NSNumber)?.doubleValue,
                response: response, track: track)
        }
    }

    private static func qqMusic(_ track: Track) async throws -> [LyricsCandidate] {
        let body: [String: Any] = ["req_1": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
            "param": ["num_per_page": 20, "page_num": 1, "query": "\(track.name) \(track.artistNames)", "search_type": 0]]]
        let json = try await request("https://u6.y.qq.com/cgi-bin/musicu.fcg", body: body, referer: "https://c.y.qq.com/")
        let req = json["req_1"] as? [String: Any]
        let data = req?["data"] as? [String: Any]
        let bodyData = data?["body"] as? [String: Any]
        let songs = (bodyData?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        let matches = songs.compactMap { song -> ([String: Any], Double)? in
            let artists = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let album = (song["album"] as? [String: Any])?["name"] as? String
            guard song["mid"] is String,
                  let score = LyricsMatching.metadataScore(title: song["title"] as? String ?? "", artists: artists, album: album,
                       duration: (song["interval"] as? NSNumber)?.doubleValue, track: track) else { return nil }
            return (song, score)
        }.sorted { $0.1 > $1.1 }
        var results: [LyricsCandidate] = []
        for (song, _) in matches.prefix(3) {
            try Task.checkCancellation()
            let mid = song["mid"] as! String
            do {
                let response = try await qqLyrics(songID: (song["id"] as? NSNumber)?.intValue, mid: mid)
                if let candidate = makeCandidate(source: .qqMusic, id: mid, title: song["title"] as? String ?? "",
                    artists: (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                    album: (song["album"] as? [String: Any])?["name"] as? String,
                    duration: (song["interval"] as? NSNumber)?.doubleValue, response: response, track: track) {
                    results.append(candidate)
                }
            } catch { try Task.checkCancellation() }
        }
        return results
    }

    private static func qqLyrics(songID: Int?, mid: String) async throws -> LyricResponse {
        if let songID {
            for requestsQRC in [true, false] {
                do {
                    let payload = try await qqPlayLyricInfo(songID: songID, mid: mid, requestsQRC: requestsQRC)
                    let response = try qqLyricsResponse(payload, base64Encoded: true)
                    guard response.yrc != nil else { return response }
                    // QQ's line timeline may differ from its QRC timeline.
                    // Preserve both so the shared parser can align translations.
                    var fallbackLRC: String?
                    do {
                        let fallback = try await qqPlayLyricInfo(songID: songID, mid: mid, requestsQRC: false)
                        fallbackLRC = try qqLyricsResponse(fallback, base64Encoded: true).lrc?.lyric
                    } catch { try Task.checkCancellation() }
                    return try qqLyricsResponse(payload, base64Encoded: true, fallbackLRC: fallbackLRC)
                } catch { try Task.checkCancellation() }
            }
        }
        let json = try await request("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
            query: ["songmid": mid, "format": "json", "nobase64": "1", "g_tk": "5381", "platform": "yqq"],
            referer: "https://c.y.qq.com/")
        return try qqLyricsResponse(json, base64Encoded: false)
    }

    private static func qqPlayLyricInfo(songID: Int, mid: String, requestsQRC: Bool) async throws -> [String: Any] {
        // Request QRC first, following MeloX's QQ Music client profile.
        let body: [String: Any] = ["comm": ["ct": 11, "cv": "1003006", "uin": 0, "tmeAppID": "qqmusiclight"],
            "req_0": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                      "param": ["songID": songID, "songMID": mid, "crypt": 1, "ct": 19, "cv": 2111,
                                "trans": 1, "roma": 0, "qrc": requestsQRC ? 1 : 0,
                                "qrc_t": 0, "lrc_t": 0, "trans_t": 0, "type": 0]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg",
            query: ["data": String(decoding: data, as: UTF8.self)], referer: "https://y.qq.com/")
        guard (json["code"] as? Int) == 0,
              let result = json["req_0"] as? [String: Any], (result["code"] as? Int) == 0,
              let lyrics = result["data"] as? [String: Any] else { throw Failure.invalidResponse }
        return lyrics
    }

    static func qqLyricsResponse(_ json: [String: Any], base64Encoded: Bool,
                                 fallbackLRC: String? = nil) throws -> LyricResponse {
        guard let original = json["lyric"] as? String else { throw Failure.invalidResponse }
        func decoded(_ text: String) -> String? {
            if !base64Encoded { return decodeEntities(text) }
            // QRC remains encrypted hex even when the response says crypt=0.
            if let decoded = QQMusicLyricDecoder.decode(text) { return decoded }
            guard let data = Data(base64Encoded: text), let value = String(data: data, encoding: .utf8) else { return nil }
            return decodeEntities(value)
        }
        guard let lrc = decoded(original) else { throw Failure.invalidResponse }
        let translation = (json["trans"] as? String).flatMap(decoded).map { text in
            text.components(separatedBy: .newlines).filter { line in
                line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) != "//"
            }.joined(separator: "\n")
        }
        let yrc = QRCLyricNormalizer.normalize(lrc)
        if !yrc.isEmpty {
            let lines = LyricsParser.parseYRC(yrc)
            guard lines.contains(where: { $0.words?.isEmpty == false }) else { throw Failure.invalidResponse }
            let generatedLRC = lines.map { line in
                let milliseconds = Int((line.time * 1000).rounded())
                return String(format: "[%02d:%02d.%03d]%@", milliseconds / 60000,
                              milliseconds / 1000 % 60, milliseconds % 1000, line.text)
            }.joined(separator: "\n")
            return try response(lrc: fallbackLRC ?? generatedLRC, translation: translation, yrc: yrc)
        }
        return try response(lrc: lrc, translation: translation)
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
        for (entity, replacement) in [("&#39;", "'"), ("&apos;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value
    }

    private static func kugou(_ track: Track) async throws -> [LyricsCandidate] {
        let json = try await request("https://lyrics.kugou.com/search", query: ["ver": "1", "man": "yes", "client": "pc",
            "keyword": "\(track.name) \(track.artistNames)", "duration": String(track.durationMS)])
        // This endpoint has no album field; leave it unknown in the shared score.
        let matches = (json["candidates"] as? [[String: Any]] ?? []).compactMap { item -> ([String: Any], Double)? in
            guard let score = LyricsMatching.metadataScore(title: item["song"] as? String ?? "",
                artists: [item["singer"] as? String ?? ""], album: nil,
                duration: ((item["duration"] as? NSNumber)?.doubleValue).map { $0 / 1000 }, track: track) else { return nil }
            return (item, score)
        }.sorted { $0.1 > $1.1 }
        var results: [LyricsCandidate] = []
        for (item, _) in matches.prefix(3) {
            try Task.checkCancellation()
            guard let id = item["id"] as? String, let key = item["accesskey"] as? String else { continue }
            do {
                let download = try await request("https://lyrics.kugou.com/download", query: ["ver": "1", "client": "pc", "id": id,
                    "accesskey": key, "fmt": "krc", "charset": "utf8"])
                guard let content = download["content"] as? String else { continue }
                let response = try decodeKRC(content)
                if let candidate = makeCandidate(source: .kugou, id: id, title: item["song"] as? String ?? "",
                    artists: [item["singer"] as? String ?? ""], album: nil,
                    duration: ((item["duration"] as? NSNumber)?.doubleValue).map { $0 / 1000 }, response: response, track: track) {
                    results.append(candidate)
                }
            } catch { try Task.checkCancellation() }
        }
        return results
    }

    static func decodeKRC(_ content: String) throws -> LyricResponse {
        guard let data = Data(base64Encoded: content), data.starts(with: [0x6b, 0x72, 0x63, 0x31]) else { throw Failure.invalidResponse }
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]
        let compressed = data.dropFirst(4).enumerated().map { $0.element ^ key[$0.offset % key.count] }
        var output = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        var size = uLongf(output.count)
        let status = compressed.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in uncompress(out.baseAddress!, &size, input.baseAddress!, uLong(compressed.count)) }
        }
        guard status == Z_OK, let text = String(bytes: output.prefix(Int(size)), encoding: .utf8) else { throw Failure.invalidResponse }
        return try parseKRC(text)
    }

    static func parseKRC(_ text: String) throws -> LyricResponse {
        let translations = krcTranslations(text)
        var lrc: [String] = [], yrc: [String] = [], translatedLRC: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
            guard let head = line.firstMatch(of: #/^\[(\d+),(\d+)\]/#), let start = Int(head.output.1) else { continue }
            let words = line.matches(of: #/<(\d+),(\d+),\d+>(.*?)(?=<\d+,\d+,\d+>|$)/#)
            guard !words.isEmpty else { continue }
            let plain = words.map { String($0.output.3) }.joined()
            let timestamp = String(format: "[%02d:%02d.%03d]", start / 60000, start / 1000 % 60, start % 1000)
            // KRC translations align by lyric-line index, including empty or
            // “//” placeholders. Never compact them before matching timestamps.
            let lineIndex = lrc.count
            if lineIndex < translations.count,
               let translation = translations[lineIndex], !translation.isEmpty, translation != "//" {
                translatedLRC.append(timestamp + translation)
            }
            lrc.append(timestamp + plain)
            let timed = words.compactMap { word -> String? in
                guard let offset = Int(word.output.1), offset <= Int.max - start else { return nil }
                return "(\(start + offset),\(word.output.2),0)\(word.output.3)"
            }
            guard timed.count == words.count else { continue }
            yrc.append("[\(start),\(head.output.2)]\(timed.joined())")
        }
        return try response(lrc: lrc.joined(separator: "\n"),
                            translation: translatedLRC.isEmpty ? nil : translatedLRC.joined(separator: "\n"),
                            yrc: yrc.joined(separator: "\n"))
    }

    private static func krcTranslations(_ text: String) -> [String?] {
        guard let tag = text.range(of: "[language:"),
              let end = text[tag.upperBound...].firstIndex(of: "]"),
              let data = Data(base64Encoded: String(text[tag.upperBound..<end])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              // Type 0 contains pronunciation; type 1 contains translations.
              let translation = content.first(where: { ($0["type"] as? Int) == 1 }),
              let rows = translation["lyricContent"] as? [Any] else { return [] }
        return rows.map { row in
            ((row as? [Any])?.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
