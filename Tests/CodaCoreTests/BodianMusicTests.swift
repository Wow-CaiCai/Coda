import Foundation
import Testing
@testable import CodaCore

/// Answers Bodian requests from canned JSON, recording what was asked.
private final class BodianFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func reset(_ value: [String: [String: Any]]) { lock.withLock { responses = value; seen = [] } }
    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            recorded.httpBody = data
        }
        let body = Self.lock.withLock { () -> [String: Any] in
            Self.seen.append(recorded)
            return Self.responses[path] ?? ["code": 404]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private func fixtureAPI(_ responses: [String: [String: Any]]) -> BodianMusicAPI {
    BodianFixture.reset(responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BodianFixture.self]
    return BodianMusicAPI(configuration: configuration, deviceID: String(repeating: "a", count: 32),
                          now: { Date(timeIntervalSince1970: 1_700_000_000) })
}

private func query(_ request: URLRequest) -> [String: String] {
    Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
               uniquingKeysWith: { $1 })
}

/// Times out the first request, then answers like the service.
private final class StaleConnectionFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var attempts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let attempt = Self.lock.withLock { Self.attempts += 1; return Self.attempts }
        if attempt == 1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let data = try! JSONSerialization.data(withJSONObject: ["code": 200, "data": ["qrCode": "k"]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct BodianMusicTests {
    @MainActor @Test func aStaleConnectionIsRetriedOnce() async throws {
        StaleConnectionFixture.attempts = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StaleConnectionFixture.self]
        let api = BodianMusicAPI(configuration: configuration, deviceID: String(repeating: "c", count: 32))
        #expect(try await api.qrCode().key == "k")
        #expect(StaleConnectionFixture.attempts == 2)
        #expect(!BodianMusicAPI.retriesOnFreshConnection(.notConnectedToInternet))
    }

    // Expected values come from bodian-music-api 0.1.2's signQuery.
    @Test func signatureMatchesTheDesktopClient() {
        let query = BodianMusicAPI.formEncode([("musicId", "228908"), ("freeSign", ""), ("uid", "-1"), ("token", ""), ("timestamp", "1700000000000")])
        #expect(BodianMusicAPI.sign(path: "/api/play/music/v2/checkRight", query: query) == "542659bbd53276d8ada708cd10b2f7b6")
        let login = BodianMusicAPI.formEncode([("uid", "-1"), ("token", ""), ("timestamp", "1700000000000")])
        #expect(BodianMusicAPI.sign(path: "/api/ucenter/users/login", query: login, body: #"{"authType":10,"qrCode":"abc"}"#)
                == "7f78284f248ae3b2a3e12d920b2e46cf")
        let search = BodianMusicAPI.formEncode([("keyword", "周杰伦 晴天"), ("uid", "-1"), ("token", ""), ("timestamp", "1")])
        #expect(BodianMusicAPI.sign(path: "/api/search/x", query: search) == "e54edf1ee80c358fdc48bcf303b8581a")
    }

    @Test func queryEncodingMatchesURLSearchParams() {
        #expect(BodianMusicAPI.formEncode([("keyword", "周杰伦 晴天*~!"), ("a", "x/y")])
                == "keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6+%E6%99%B4%E5%A4%A9*%7E%21&a=x%2Fy")
    }

    @Test func wordTimingDecodesIntoKaraokeLines() {
        let source = "[kuwo:127]\n[ti:晴天]\n[00:00.000]<1120,-1120>晴<2400,160>天\n[00:02.250]<3150,-3150>词<6750,450>："
        let response = BodianMusicAPI.lyricResponse(source)
        #expect(response.lrc?.lyric == "[00:00.000]晴天\n[00:02.250]词：")
        #expect(response.yrc?.lyric == "[0,320](0,160,0)晴(160,160,0)天\n[2250,900](2250,450,0)词(2700,450,0)：")
        #expect(response.nolyric == false)
        #expect(LyricsParser.parseYRC(response.yrc?.lyric ?? "").count == 2)
    }

    @Test func repeatedTimestampsBecomeTranslations() {
        let response = BodianMusicAPI.lyricResponse("[kuwo:11]\n[00:01.00]<0,0>Hello\n[00:01.00]<0,0>你好\n[00:03.00]<0,0>World")
        #expect(response.lrc?.lyric == "[00:01.00]Hello\n[00:03.00]World")
        #expect(response.tlyric?.lyric == "[00:01.00]你好")
    }

    @Test func plainLyricsHaveNoWordTiming() {
        let response = BodianMusicAPI.lyricResponse("[00:01.00]第一行\n[00:02.00]第二行")
        #expect(response.yrc == nil)
        #expect(response.lrc?.lyric == "[00:01.00]第一行\n[00:02.00]第二行")
        #expect(BodianMusicAPI.lyricResponse("").nolyric == true)
    }

    @Test func loginRejectsContradictoryIdentities() throws {
        let credentials = try BodianMusicAPI.loginCredentials(["token": "t0", "userInfo": ["uid": 123, "nickname": "波点", "headImg": "http://img1.kuwo.cn/a.jpg"]])
        #expect(credentials == ["userid": "123", "token": "t0", "nickname": "波点", "avatar": "https://img1.kuwo.cn/a.jpg"])
        #expect(throws: BodianError.invalidResponse) { try BodianMusicAPI.loginCredentials(["token": "t", "id": 1, "userInfo": ["uid": 2]]) }
        #expect(throws: BodianError.invalidResponse) { try BodianMusicAPI.loginCredentials(["token": " ", "uid": 1]) }
        #expect(throws: BodianError.invalidResponse) { try BodianMusicAPI.loginCredentials(["token": "t", "uid": "012"]) }
    }

    @Test func businessCodesMapToErrors() {
        #expect(throws: BodianError.authRequired) { try BodianMusicAPI.check(["code": 11012]) }
        #expect(throws: BodianError.notPlayable) { try BodianMusicAPI.check(["code": 20018]) }
        #expect(throws: BodianError.regionRestricted("仅限大陆")) { try BodianMusicAPI.check(["code": 407, "msg": " 仅限大陆 "]) }
        #expect(throws: BodianError.business(-10)) { try BodianMusicAPI.check(["code": -10]) }
    }

    @Test func coversUpgradeOnlySingleLevelKuwoHosts() {
        #expect(BodianMusicAPI.coverURL("http://img4.kuwo.cn/star/a.jpg")?.absoluteString == "https://img4.kuwo.cn/star/a.jpg")
        #expect(BodianMusicAPI.coverURL("http://img1.kwcdn.kuwo.cn/star/a.jpg")?.absoluteString == "http://img1.kwcdn.kuwo.cn/star/a.jpg")
        #expect(BodianMusicAPI.coverURL("") == nil)
    }

    @Test func songNormalizationKeepsCatalogReferences() throws {
        let song = try #require(BodianMusicAPI.song([
            "id": 228908, "name": "晴天", "songName": "晴天 (Live)", "album": "叶惠美", "albumId": 1293,
            "albumPic": "http://img4.kuwo.cn/star/albumcover/800/x.jpg", "duration": 269,
            "artists": [["id": 336, "name": "周杰伦"], ["id": 0, "name": "嘉宾"]], "payInfo": ["paytype": 3],
        ]))
        #expect(song.id == 228908 && song.source == .bodian && song.name == "晴天 (Live)")
        #expect(song.artists == "周杰伦 / 嘉宾" && song.duration == 269 && song.fee == 3)
        #expect(song.bodian?.musicID == "228908" && song.bodian?.albumID == "1293")
        #expect(song.bodian?.artists?.map(\.id) == ["336", ""])
        #expect(song.identityKey == "bodian-228908")
        let decoded = try JSONDecoder().decode(ProviderSong.self, from: JSONEncoder().encode(song))
        #expect(decoded.bodian == song.bodian)
        #expect(BodianMusicAPI.song(["id": 0]) == nil)
    }

    @MainActor @Test func playbackChecksRightsBeforeAskingForAudio() async throws {
        let api = fixtureAPI([
            "/api/play/music/v2/checkRight": ["code": 200, "data": ["status": 1]],
            "/api/play/music/v2/audioUrl": ["code": 200, "data": ["audioHttpsUrl": "https://bd-lv.kuwo.cn/a.flac", "format": "flac", "bitrate": 2000, "duration": 286]],
        ])
        let resource = try await api.playback(.init(musicID: "22842713"), quality: .hires)
        #expect(resource.url == "https://bd-lv.kuwo.cn/a.flac" && resource.quality == .lossless && resource.durationMS == 286_000)
        let requests = BodianFixture.requests
        #expect(requests.map(\.url!.path) == ["/api/play/music/v2/checkRight", "/api/play/music/v2/audioUrl"])
        let audio = query(requests[1])
        #expect(audio["br"] == "2000kflac" && audio["devId"] == String(repeating: "a", count: 32))
        #expect(audio["timestamp"] == "1700000000000" && audio["sign"]?.count == 32)
        // URLSession cannot send a GET body; the parameters travel in the query.
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(requests[0].value(forHTTPHeaderField: "devid") == String(repeating: "a", count: 32))
    }

    @MainActor @Test func previewOnlySongsAreNotServed() async {
        let api = fixtureAPI(["/api/play/music/v2/checkRight": ["code": 200, "data": ["status": 3, "audition": ["start": 0, "end": 29, "https": "https://x/y.mp3"]]]])
        await #expect(throws: BodianError.previewOnly) { try await api.playback(.init(musicID: "228908"), quality: .exhigh) }
        #expect(BodianFixture.requests.count == 1)
    }

    @MainActor @Test func qrLoginReturnsCredentialsWithoutAdoptingThem() async throws {
        let api = fixtureAPI([
            "/api/ucenter/login/qrCode": ["code": 200, "data": ["qrCode": "70e83aa8a9ba675b"]],
            "/api/ucenter/login/qrCodeStatus": ["code": 200, "data": ["status": 3]],
            "/api/ucenter/users/login": ["code": 200, "data": ["token": "tok", "uid": 42, "userInfo": ["uid": 42, "nickname": "Coda"]]],
        ])
        let qr = try await api.qrCode()
        #expect(qr.scanURL.absoluteString == "https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id=70e83aa8a9ba675b")
        let state = try await api.pollQRCode(qr.key)
        #expect(state == .confirmed(["userid": "42", "token": "tok", "nickname": "Coda"]))
        #expect(!api.isLoggedIn)
        let login = try #require(BodianFixture.requests.last)
        #expect(login.httpMethod == "POST")
        #expect(String(decoding: login.httpBody ?? Data(), as: UTF8.self) == #"{"authType":10,"qrCode":"70e83aa8a9ba675b"}"#)
        #expect(try await api.pollQRCode(qr.key) == .expired)
    }

    @MainActor @Test func scannedButUnconfirmedQRKeepsWaiting() async throws {
        let api = fixtureAPI([
            "/api/ucenter/login/qrCode": ["code": 200, "data": ["qrCode": "k"]],
            "/api/ucenter/login/qrCodeStatus": ["code": 200, "data": ["status": 3]],
            "/api/ucenter/users/login": ["code": 11027],
        ])
        let qr = try await api.qrCode()
        #expect(try await api.pollQRCode(qr.key) == .scanned)
        #expect(!api.isQRCodeExpired(qr.key))
    }

    @MainActor @Test func playlistPagingFollowsTheReportedTotal() async throws {
        func row(_ id: Int) -> [String: Any] { ["id": id, "name": "S\(id)", "artist": "A"] }
        // The server omits unavailable songs: a 99-row first page still continues.
        let api = fixtureAPI([
            "/api/service/playlist/info/77": ["code": 200, "data": ["id": 77, "name": "歌单", "musicCount": 150, "sourceType": 4]],
            "/api/service/playlist/77/musicList": ["code": 200, "data": ["total": 150, "list": (1...99).map(row)]],
        ])
        let detail = try await api.playlistDetail(.init(playlistID: "77", source: 4))
        #expect(detail.playlist?.name == "歌单" && detail.playlist?.bodian == BodianPlaylistReference(playlistID: "77", source: 4))
        let pages = BodianFixture.requests.filter { $0.url!.path.hasSuffix("musicList") }.map { query($0)["pn"] }
        #expect(pages == ["1", "2"])
        #expect(detail.songs.count == 198)
    }

    @MainActor @Test func rejectedSessionIsCleared() async throws {
        BodianFixture.reset(["/api/service/playlist/fond": ["code": 11012]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodianFixture.self]
        let api = BodianMusicAPI(configuration: configuration, deviceID: String(repeating: "b", count: 32))
        try api.restore(["userid": "42", "token": "tok"])
        #expect(try await api.validity(credentials: ["userid": "42", "token": "other"]) == .invalid)
        #expect(api.isLoggedIn, "validating another account must not touch the active one")
        let request = try #require(BodianFixture.requests.last)
        #expect(request.value(forHTTPHeaderField: "token") == "other" && query(request)["uid"] == "42")
    }

    @Test func aiPlaylistGroupsOpenByPosition() {
        let groups: [[String: Any]] = [
            ["title": "华文流行极致", "passRecName": "0_15", "songs": [["id": 1, "name": "A", "albumPic": "https://img4.kuwo.cn/a.jpg"]]],
            ["title": "空分组", "songs": []],
            ["passRecName": "4_119", "songs": [["id": 2, "name": "B"]]],
        ]
        let lists = BodianMusicAPI.aiPlaylists(groups)
        #expect(lists.map(\.name) == ["华文流行极致", "4_119"])
        #expect(lists.map { $0.bodian?.aiIndex } == [0, 2])
        #expect(lists[0].bodian?.passRecName == "0_15" && lists[0].bodian?.playlistID == "ai:0:0_15")
        #expect(lists[0].coverURL?.absoluteString == "https://img4.kuwo.cn/a.jpg")
    }

    @Test func homeModulesMapToSlots() {
        #expect([3, 4, 5, 10, 11, 1, 2].map(HomeDiscoverySlot.bodian(moduleType:)) ==
                [.encounterSongs, .personalPlaylists, .treasurePlaylists, .similarSongs, .themePlaylists, nil, nil])
        #expect(MusicProvider.bodian.homeDiscoverySlots.filter(\.showsSongRows) == [.encounterSongs, .similarSongs])
        #expect(HomeDiscoverySlot.similarSongs.requiresLogin(on: .bodian))
    }

    @Test func membershipFollowsTheOfficialTiers() {
        let future = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        #expect(MusicMembership.bodian(nil) == .unknown)
        #expect(MusicMembership.bodian(["isVip": 0, "vipType": 0]) == .none)
        #expect(MusicMembership.bodian(["isVip": 1, "vipType": 1, "payVipType": 2, "expireDate": future]) == .bodianVIP)
        #expect(MusicMembership.bodian(["isBigVipBoolean": true, "vipType": 1, "payVipType": 1]) == .bodianBigVIP)
        #expect(MusicMembership.bodian(["isVip": 1, "vipType": 1, "expireDate": 1_600_000_000_000]) == .none)
    }

    @MainActor @Test func chartsSkipLinkOnlyEntries() async throws {
        let api = fixtureAPI(["/api/service/home/bangNew": ["code": 200, "data": [
            ["moduleName": "置顶位", "bangList": [["id": 16, "name": "热歌榜", "total": 100, "musics": [["id": 9, "name": "S"]]]]],
            ["moduleName": "H5榜单", "bangList": [["name": "腾讯音乐榜", "bangType": "qq"]]],
        ]]])
        let charts = try await api.charts()
        #expect(charts.map(\.playlist.name) == ["热歌榜"])
        #expect(charts[0].playlist.bodian == BodianPlaylistReference(playlistID: "16", source: 0, isChart: true))
        #expect(charts[0].preview.map(\.id) == [9])
    }

    @MainActor @Test func searchPlaylistsReadSnakeCaseRows() async throws {
        let api = fixtureAPI(["/api/search/playlist/list": ["code": 200, "data": ["total": 145, "resultList": [
            ["id": 2867496601, "name": "歌单", "musicnum": 177, "source": 4, "creator_id": 300685, "pic": "http://img1.kwcdn.kuwo.cn/x.jpg"],
        ]]]])
        let page = try await api.searchPlaylists(keyword: "周杰伦", limit: 30, offset: 0)
        #expect(page.total == 145 && page.playlists.first?.trackCount == 177 && page.playlists.first?.ownerID == "300685")
        #expect(page.playlists.first?.bodian == BodianPlaylistReference(playlistID: "2867496601", source: 4))
    }

    @MainActor @Test func collectionWritesNameTheTargetState() async throws {
        let api = fixtureAPI(["/api/service/collect": ["code": 200, "data": [:]]])
        try api.restore(["userid": "42", "token": "tok"])
        try await api.setCollected(.artist, id: "336", saved: true)
        try await api.setCollected(.album, id: "1293", saved: false)
        let bodies = BodianFixture.requests.map { try! JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as! [String: Any] }
        #expect(bodies[0]["source"] as? Int == 7 && bodies[0]["op"] as? Int == 1 && bodies[0]["token"] as? String == "tok")
        #expect(bodies[0]["sourceId"] as? [Int] == [336] && bodies[0]["uid"] as? Int == 42)
        #expect(bodies[1]["source"] as? Int == 6 && bodies[1]["op"] as? Int == 2 && bodies[1]["token"] == nil)
        #expect(BodianFixture.requests.allSatisfy { $0.httpMethod == "POST" && query($0)["sign"]?.count == 32 })
    }

    @MainActor @Test func commentsUseAndroidHeadersAndFixedPages() async throws {
        let api = fixtureAPI(["/api/comments/v3/new": ["code": 200, "data": ["comment_total": 31351, "more": true, "comment_list": [
            ["id": 5, "content": "好听", "nickname": "A", "headImg": "https://bodianimgcdn.kuwo.cn/a.jpg", "likeCount": 3, "createTime": "2021-12-13"],
        ]]]])
        let page = try await api.comments(musicID: "228908", sort: .latest, page: 2)
        let request = try #require(BodianFixture.requests.last)
        #expect(request.value(forHTTPHeaderField: "plat") == "android")
        #expect(query(request)["rn"] == "30" && query(request)["pn"] == "2" && query(request)["moduleType"] == "2")
        #expect(page.total == 31351 && page.more && page.comments.first?.likedCount == 3)
        #expect(page.comments.first?.time == ISO8601DateFormatter().date(from: "2021-12-12T16:00:00Z"))
    }

    @Test func lyricsAutomaticSelectionIncludesBodian() {
        #expect(LyricsSource.providers.contains(.bodian))
        #expect(LyricsSource.bodian.title == "波点音乐")
    }

    @MainActor @Test func recentPlaysReadTheSyncedHistory() async throws {
        let api = fixtureAPI(["/api/playlist/history/page": ["code": 200, "data": ["total": 2, "list": [
            ["id": 386305156, "name": "恋人", "artist": "李荣浩"], ["id": 316388, "name": "越来越不懂", "artist": "蔡健雅"],
        ]]]])
        try api.restore(["userid": "42", "token": "tok"])
        let songs = try await api.recentPlays()
        #expect(songs.map(\.id) == [386305156, 316388])
        let request = try #require(BodianFixture.requests.last)
        #expect(query(request)["sourceType"] == "1" && query(request)["pn"] == "1" && query(request)["rn"] == "200")
        #expect(BodianFixture.requests.count == 1)
    }

    @MainActor @Test func startedSongsAreReportedAsTheirAccount() async throws {
        let api = fixtureAPI(["/api/playlist/history/add": ["code": 200]])
        try await api.appendRecentPlay(musicID: "228908", account: ["userid": "7", "token": "other"])
        let request = try #require(BodianFixture.requests.last)
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "token") == "other" && query(request)["uid"] == "7")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["sourceType"] as? Int == 1)
        #expect((body["items"] as? [[String: Any]])?.first?["sourceId"] as? Int == 228908)
        #expect(body["uid"] == nil && body["token"] == nil)
        await #expect(throws: BodianError.authRequired) { try await api.appendRecentPlay(musicID: "1", account: [:]) }
    }
}
