import Foundation
import Testing
@testable import CodaCore

/// Hits Bodian anonymously; run with CODA_BODIAN_LIVE=1 (playback needs a mainland network).
@MainActor @Suite struct BodianLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODA_BODIAN_LIVE"] == "1"))
    func anonymousCatalogAndPlayback() async throws {
        let api = BodianMusicAPI(deviceID: BodianMusicAPI.makeDeviceID())
        let search = try await api.searchSongs(keyword: "周杰伦 晴天", limit: 10, offset: 0)
        let song = try #require(search.songs.first { $0.bodian?.albumID != nil })
        let reference = try #require(song.bodian)
        let lyric = try await api.lyric(musicID: reference.musicID)
        #expect(lyric.yrc?.lyric?.isEmpty == false)
        let album = try await api.albumDetail(try #require(reference.albumID))
        #expect(album.album?.name.isEmpty == false && !album.songs.isEmpty)
        let artistID = try #require(reference.artists?.first?.id)
        let artist = try await api.artistDetail(artistID)
        #expect(artist.artist?.name.isEmpty == false && !artist.songs.isEmpty)
        #expect(try await api.artistAlbums(artistID, limit: 5, offset: 0).albums.count == 5)
        let lists = try await api.recommendedPlaylists(limit: 5)
        let detail = try await api.playlistDetail(try #require(lists.first?.bodian))
        #expect(!detail.songs.isEmpty)
        #expect(!(try await api.homeSongs()).isEmpty)
        let qr = try await api.qrCode()
        #expect(try await api.pollQRCode(qr.key) == .waiting)
        // A free song plays in full without an account.
        let free = try await api.searchSongs(keyword: "风居住的街道 Piano ver", limit: 10, offset: 0).songs
        var played = false
        for candidate in free {
            guard let item = candidate.bodian, let resource = try? await api.playback(item, quality: .exhigh) else { continue }
            #expect(resource.url.hasPrefix("https://")); played = true; break
        }
        #expect(played)
    
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODA_BODIAN_LIVE"] == "1"))
    func anonymousDiscovery() async throws {
        let api = BodianMusicAPI(deviceID: BodianMusicAPI.makeDeviceID())
        #expect(try await api.searchAlbums(keyword: "周杰伦", limit: 5, offset: 0).albums.count == 5)
        #expect(try await api.searchArtists(keyword: "周杰伦", limit: 5, offset: 0).artists.first?.name == "周杰伦")
        let lists = try await api.searchPlaylists(keyword: "周杰伦", limit: 5, offset: 0).playlists
        #expect(lists.count == 5 && lists.allSatisfy { $0.bodian?.source == 4 })
        #expect(!(try await api.searchSuggestions(keyword: "周杰")).isEmpty)
        #expect(!(try await api.hotSearchWords()).isEmpty)
        let charts = try await api.charts()
        #expect(charts.count >= 10 && charts.allSatisfy { $0.playlist.bodian?.isChart == true })
        #expect(try await api.chartSongs(try #require(charts.first?.playlist.bodian?.playlistID)).count >= 50)
        #expect(!(try await api.categoryPlaylists(77, limit: 10, offset: 0)).playlists.isEmpty)
        let sections = try await api.homeSections()
        #expect(sections.contains { $0.type == 4 } && sections.contains { $0.type == 3 } && sections.contains { $0.type == 5 })
        let ai = try #require(sections.first { $0.type == 11 } ?? sections.first { $0.type == 4 })
        guard case .playlists(let groups) = ai.content, let reference = groups.first?.bodian else { Issue.record("no AI group"); return }
        let detail = try await api.aiPlaylist(index: try #require(reference.aiIndex), passRecName: reference.passRecName ?? "")
        #expect(detail.title == groups.first?.name && detail.songs.count >= 10)
        let comments = try await api.comments(musicID: "228908", sort: .hot, page: 1)
        #expect(comments.comments.count == 30 && comments.total > 1000 && comments.comments[0].time.timeIntervalSince1970 > 0)
        #expect(!(try await api.comments(musicID: "228908", sort: .latest, page: 1)).comments.isEmpty)
    }
}
