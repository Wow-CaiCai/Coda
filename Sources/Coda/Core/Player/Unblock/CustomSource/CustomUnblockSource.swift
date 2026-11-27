import Foundation

/// The user's imported custom sources, as one unblock source. Each enabled
/// script is tried in list order; within a script, the track's own platform
/// goes first (with its own song ID), then NetEase, QQ Music and KuGou, whose
/// song IDs Coda can find by search.
struct CustomUnblockSource: UnblockSource {
    let id = AudioSourceID.custom

    /// Platforms Coda can supply a song ID for, in fallback order.
    static let searchablePlatforms = ["wy", "tx", "kg"]
    /// LX quality tokens from lowest to highest.
    static let tokenOrder = ["128k", "320k", "flac", "flac24bit"]
    /// Streams below this are previews or placeholders, not the track.
    static let minimumBitrate: Double = 96_000

    func isAvailable() async -> Bool {
        await CustomSourceStore.shared.hasEnabledSources
    }

    func isSignedIn() async -> Bool { false }

    func resolve(_ query: UnblockQuery, quality: AudioQuality) async throws -> UnblockStream? {
        let ids = await CustomSourceStore.shared.enabledSources.map(\.id)
        var lastError: Error?
        for sourceID in ids {
            try Task.checkCancellation()
            let runtime: LXScriptRuntime
            let capabilities: LXScriptRuntime.Capabilities
            do {
                (runtime, capabilities) = try await CustomSourceStore.shared.runtime(for: sourceID)
            } catch {
                lastError = error
                continue
            }
            for platform in Self.platforms(for: query.origin, declared: capabilities) {
                try Task.checkCancellation()
                do {
                    guard let info = try await Self.musicInfo(platform: platform, query: query) else { continue }
                    let token = Self.token(for: quality, declared: capabilities[platform] ?? [])
                    let address = try await runtime.musicURL(platform: platform, quality: token, musicInfo: info)
                    if let stream = await Self.stream(address, durationMS: query.durationMS) { return stream }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        // An error means "try again later"; only a clean miss is remembered.
        if let lastError { throw lastError }
        return nil
    }

    func qualityOptions(_ query: UnblockQuery) async throws -> [AudioQualityOption] {
        var options: [AudioQualityOption] = []
        for tier: AudioQuality in [.standard, .exhigh, .lossless, .hires] {
            guard let stream = try? await resolve(query, quality: tier), let served = stream.quality,
                  !options.contains(where: { $0.quality == served }) else { continue }
            options.append(.init(quality: served, title: stream.title ?? AudioQualityOption.unifiedTitle(quality: served)))
        }
        return options
    }

    // MARK: - Platforms and tiers

    static func platforms(for origin: MusicProvider, declared: LXScriptRuntime.Capabilities) -> [String] {
        let own: String? = switch origin {
        case .netease: "wy"
        case .qq: "tx"
        case .kugou: "kg"
        case .qishui, .bodian: nil
        }
        let order = (own.map { [$0] } ?? []) + searchablePlatforms.filter { $0 != own }
        return order.filter { declared[$0] != nil }
    }

    /// The highest declared token not above the wanted tier; the lowest when
    /// all are above it; the wanted token when the script lists none.
    static func token(for quality: AudioQuality, declared: [String]) -> String {
        let wanted: String
        switch quality {
        case .standard: wanted = "128k"
        case .higher, .exhigh: wanted = "320k"
        case .lossless: wanted = "flac"
        case .hires, .jyeffect, .sky, .jymaster: wanted = "flac24bit"
        }
        let known = tokenOrder.filter(declared.contains)
        guard !known.isEmpty, let limit = tokenOrder.firstIndex(of: wanted) else { return wanted }
        return known.last { tokenOrder.firstIndex(of: $0)! <= limit } ?? known[0]
    }

    // MARK: - Song IDs

    /// The LX `musicInfo` for one platform, or nil when Coda cannot find the song there.
    static func musicInfo(platform: String, query: UnblockQuery) async throws -> [String: Any]? {
        var info: [String: Any] = [
            "name": query.title,
            "singer": query.artists.joined(separator: "、"),
            "albumName": query.album,
            "interval": interval(query.durationMS),
            "source": platform,
            "img": "",
            "albumId": "",
            "types": [] as [Any],
            "_types": [:] as [String: Any],
            "typeUrl": [:] as [String: Any],
        ]
        switch platform {
        case "wy":
            guard let id = try await NeteaseSongLookup.shared.songID(for: query) else { return nil }
            info["songmid"] = String(id)
        case "tx":
            var mid = query.origin == .qq ? query.qqMid : nil
            var mediaMid = query.origin == .qq ? query.qqMediaMid : nil
            var songID = query.origin == .qq ? query.platformSongID : nil
            if mid == nil {
                let api = await UnblockSessionPool.shared.qqAPI()
                let song = try await UnblockMatchCache.shared.song(.qq, query) {
                    try await api.searchSongs(keyword: query.keyword, limit: 10)
                }
                mid = song?.qqMid
                mediaMid = song?.qqMediaMid
                songID = song?.id
            }
            guard let mid else { return nil }
            info["songmid"] = mid
            info["strMediaMid"] = mediaMid ?? mid
            info["songId"] = songID ?? 0
        case "kg":
            var hash = query.origin == .kugou ? query.kugouHash : nil
            var albumAudioID = query.origin == .kugou ? query.kugouAlbumAudioID : nil
            if hash == nil {
                let api = await UnblockSessionPool.shared.kugouAPI()
                let song = try await UnblockMatchCache.shared.song(.kugou, query) {
                    try await api.searchSongs(keyword: query.keyword, limit: 10)
                }
                hash = song?.kugouHash
                albumAudioID = song?.kugouAlbumAudioId
            }
            guard let hash else { return nil }
            info["hash"] = hash.uppercased()
            info["songmid"] = albumAudioID ?? hash.uppercased()
            info["albumAudioId"] = albumAudioID ?? ""
        default:
            return nil
        }
        return info
    }

    private static func interval(_ durationMS: Int) -> String {
        let seconds = max(0, durationMS / 1000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Stream check

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// Reads the first bytes of the address to learn its format and size, and
    /// drops previews: a short file over a full-length track reads as a very
    /// low bitrate. Servers that refuse the probe still get to play.
    static func stream(_ address: String, durationMS: Int) async -> UnblockStream? {
        guard let url = URL(string: address) else { return nil }
        guard let probe = await probe(url) else { return UnblockStream(url: url, quality: nil) }
        let seconds = Double(durationMS) / 1000
        let bitrate = AudioQualityOption.estimatedBitrate(byteCount: probe.byteCount, durationSeconds: seconds)
        if let bitrate, bitrate < minimumBitrate { return nil }
        let served = AudioQualityCheck.flacTier(header: probe.header)
            ?? AudioQualityCheck.lossyTier(bitrate: bitrate.map { $0 * 0.95 })
        let title = served.map {
            AudioQualityOption.unifiedTitle(quality: $0, reportedBitrate: nil,
                                            byteCount: probe.byteCount, durationSeconds: seconds)
        }
        return UnblockStream(url: url, quality: served, bitrate: bitrate.map { Int($0) }, title: title)
    }

    private struct Probe {
        let header: Data
        let byteCount: Double?
    }

    private static func probe(_ url: URL) async -> Probe? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("bytes=0-41", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await probeSession.bytes(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        var header = Data()
        do {
            for try await byte in bytes {
                header.append(byte)
                if header.count == 42 { break }
            }
        } catch { return nil }
        let total: Double?
        if http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let size = range.split(separator: "/").last.flatMap({ Double($0) }) {
            total = size
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            total = Double(http.expectedContentLength)
        } else {
            total = nil
        }
        return Probe(header: header, byteCount: total)
    }
}
