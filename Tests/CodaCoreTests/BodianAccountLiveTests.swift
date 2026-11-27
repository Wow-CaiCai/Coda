import Foundation
import Testing
@testable import CodaCore

/// Round-trips collection writes on a real account; every change is undone.
/// Each test stops before writing when the account already holds its target.
/// Run with CODA_BODIAN_SESSION (the session JSON) and CODA_BODIAN_DEVICE.
@MainActor @Suite(.serialized) struct BodianAccountLiveTests {
    nonisolated private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated private static var enabled: Bool { environment["CODA_BODIAN_SESSION"] != nil }

    private func api() throws -> BodianMusicAPI {
        let session = try JSONSerialization.jsonObject(with: Data(Self.environment["CODA_BODIAN_SESSION"]!.utf8)) as! [String: String]
        let api = BodianMusicAPI(deviceID: Self.environment["CODA_BODIAN_DEVICE"] ?? BodianMusicAPI.makeDeviceID())
        try api.restore(session)
        return api
    }

    @Test(.enabled(if: enabled)) func playlistRoundTrip() async throws {
        let api = try api()
        let reference = BodianPlaylistReference(playlistID: "3676839501", source: 4)
        // Stop before writing if the account already has it, so its state is never changed.
        try #require(try await api.isPlaylistCollected(reference) == false)
        try await api.setCollected(.playlist, id: reference.playlistID, source: reference.source, saved: true)
        let saved = try await api.isPlaylistCollected(reference)
        let listed = try await api.userPlaylists().contains { $0.bodian?.playlistID == reference.playlistID && $0.isSubscribed == true }
        try await api.setCollected(.playlist, id: reference.playlistID, source: reference.source, saved: false)
        #expect(saved && listed)
        #expect(try await api.isPlaylistCollected(reference) == false)
    }

    @Test(.enabled(if: enabled)) func albumRoundTrip() async throws {
        let api = try api()
        try #require(try await api.isAlbumCollected("1293") == false)
        try await api.setCollected(.album, id: "1293", saved: true)
        let saved = try await api.isAlbumCollected("1293")
        let listed = try await api.collectedAlbums().map(\.id)
        let lists = try await api.userPlaylists().compactMap { $0.bodian?.playlistID }
        try await api.setCollected(.album, id: "1293", saved: false)
        #expect(saved == true)
        #expect(listed.contains("1293"), "collected albums: \(listed)")
        #expect(!lists.contains("1293"), "an album must not appear among playlists")
        #expect(try await api.isAlbumCollected("1293") == false)
    }

    @Test(.enabled(if: enabled)) func artistRoundTrip() async throws {
        let api = try api()
        let before = try await api.followedArtists().map(\.id)
        try #require(!before.contains("336"))
        try await api.setCollected(.artist, id: "336", saved: true)
        let after = try await api.followedArtists().map(\.id)
        try await api.setCollected(.artist, id: "336", saved: false)
        #expect(after.contains("336"), "followed: \(after)")
        #expect(!(try await api.followedArtists().map(\.id)).contains("336"))
    }

    @Test(.enabled(if: enabled)) func signedInCatalogReads() async throws {
        let api = try api()
        let started = Date()
        let album = try await api.albumDetail("1293")
        #expect(album.songs.count == 11 && album.album?.name == "叶惠美")
        let artist = try await api.artistDetail("336")
        #expect(!artist.songs.isEmpty)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// Leaves 228908 at the top of the history; the runner deletes it afterwards.
    @Test(.enabled(if: environment["CODA_BODIAN_HISTORY"] == "1")) func reportedSongTopsTheHistory() async throws {
        let api = try api()
        let before = try await api.recentPlays().map(\.id)
        try #require(!before.contains(228908))
        try await api.appendRecentPlay(musicID: "228908", account: api.credentials)
        let after = try await api.recentPlays().map(\.id)
        #expect(after.first == 228908, "history: \(after.prefix(5))")
        #expect(Array(after.dropFirst().prefix(before.count)) == before.filter { $0 != 228908 })
    }
}
