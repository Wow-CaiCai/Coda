// Bodian catalog, home, collection and comment endpoints, following the
// endpoint notes of ldm0715/bowen_music (GPL-3.0); see ThirdPartyNotices/Bodian.md.
import Foundation

extension BodianMusicAPI {
    struct HomeSection {
        enum Content { case songs([ProviderSong]), playlists([ProviderPlaylist]) }
        let moduleID: Int
        let type: Int
        let title: String
        let content: Content
    }

    struct Chart {
        let playlist: ProviderPlaylist
        let preview: [ProviderSong]
    }

    struct Comment {
        let id: Int
        let content: String
        let nickname: String
        let avatarURL: URL?
        let time: Date
        let likedCount: Int
    }

    // MARK: Search

    private func searchPage(_ path: String, keyword: String, limit: Int, offset: Int) async throws -> (rows: [[String: Any]], total: Int?) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 500 else { return ([], 0) }
        let data = try await data(path, [("keyword", keyword)] + Self.page(limit: limit, offset: offset, firstPage: 0))
        let rows = data["resultList"] as? [[String: Any]] ?? []
        return (Array(rows.dropFirst(offset % min(max(limit, 1), 100))), Self.int(data["total"]))
    }

    func searchAlbums(keyword: String, limit: Int, offset: Int) async throws -> (albums: [ProviderAlbum], total: Int?) {
        let page = try await searchPage("search/album/list", keyword: keyword, limit: limit, offset: offset)
        return (page.rows.compactMap(Self.album), page.total)
    }

    func searchArtists(keyword: String, limit: Int, offset: Int) async throws -> (artists: [ProviderArtist], total: Int?) {
        let page = try await searchPage("search/artist/list", keyword: keyword, limit: limit, offset: offset)
        return (page.rows.compactMap { row in
            guard let id = Self.idString(row["artistId"] ?? row["id"]) else { return nil }
            return ProviderArtist(id: id, name: Self.string(row["name"]), coverURL: Self.coverURL(row["pic"]), source: .bodian)
        }, page.total)
    }

    /// Search rows are snake_case and name their track count `musicnum`.
    func searchPlaylists(keyword: String, limit: Int, offset: Int) async throws -> (playlists: [ProviderPlaylist], total: Int?) {
        let page = try await searchPage("search/playlist/list", keyword: keyword, limit: limit, offset: offset)
        return (page.rows.compactMap { row in
            var item = row
            item["musicCount"] = row["musicnum"]
            item["creatorId"] = row["creator_id"]
            return Self.playlist(item, source: Self.int(row["source"]) ?? 4)
        }, page.total)
    }

    func searchSuggestions(keyword: String) async throws -> [String] {
        let data = try await data("search/tip/v2/list", [("keyword", keyword)])
        return (data["resultList"] as? [[String: Any]] ?? []).map { Self.string($0["relword"]) }
    }

    func hotSearchWords() async throws -> [String] {
        let data = try await data("search/topic/word/list")
        return (data["hotWord"] as? [[String: Any]] ?? [])
            .sorted { (Self.int($0["sort"]) ?? 0) < (Self.int($1["sort"]) ?? 0) }
            .map { Self.string($0["key"]) }
    }

    // MARK: Charts and categories

    /// 22 public charts in groups; the H5 group links out and carries no id.
    func charts() async throws -> [Chart] {
        let json = try await call("/api/service/home/bangNew")
        let groups = json["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return groups.flatMap { $0["bangList"] as? [[String: Any]] ?? [] }.compactMap { row in
            guard let id = Self.idString(row["id"]), seen.insert(id).inserted else { return nil }
            var item = ProviderPlaylist(id: Int(id) ?? 0, name: Self.string(row["name"]), coverURL: Self.coverURL(row["pic"]),
                                        trackCount: Self.int(row["total"]) ?? 0, source: .bodian)
            item.bodian = BodianPlaylistReference(playlistID: id, source: 0, isChart: true)
            return Chart(playlist: item, preview: (row["musics"] as? [[String: Any]] ?? []).compactMap(Self.song))
        }
    }

    /// The first `limit` entries of a chart in one request (the home `bangNew` preview only carries five).
    func chartTopSongs(_ id: String, limit: Int) async throws -> [ProviderSong] {
        let data = try await data("service/bang/\(id)/musics", [("pn", "1"), ("rn", String(limit))])
        let rows = data["resultList"] as? [[String: Any]] ?? data["musics"] as? [[String: Any]] ?? []
        return Array(rows.compactMap(Self.song).prefix(limit))
    }

    func chartSongs(_ id: String) async throws -> [ProviderSong] {
        try await allPages("service/bang/\(id)/musics", field: "musics", firstPage: 1, maxItems: 300).compactMap(Self.song)
    }

    /// The 歌单广场 subcategories shown in Explore (ids from `service/category/list`).
    nonisolated static let playlistCategories: [(name: String, id: Int)] = [
        ("流行", 88), ("网红", 77), ("动漫", 84), ("古风", 79), ("金曲", 86), ("民谣", 90),
        ("摇滚", 89), ("电音", 122), ("嘻哈", 91), ("老歌", 85),
    ]

    func categoryPlaylists(_ id: Int, limit: Int, offset: Int) async throws -> (playlists: [ProviderPlaylist], hasMore: Bool) {
        let size = min(max(limit, 1), 100)
        let data = try await data("service/category/\(id)/playlist", Self.page(limit: size, offset: offset, firstPage: 1))
        let rows = data["playLists"] as? [[String: Any]] ?? []
        let total = Self.int(data["total"])
        let end = (offset / size + 1) * size
        return (rows.compactMap { Self.playlist($0) }, !rows.isEmpty && (total.map { end < $0 } ?? (rows.count == size)))
    }

    // MARK: Home

    /// The discovery page: `service/home/index` lists modules, and each module's
    /// shape follows its type. Types 3/10 are singles, 4/11 AI playlist groups
    /// (opened by position via `aiPlaylistDetail`), 5 public playlist cards.
    func homeSections() async throws -> [HomeSection] {
        let modules = (try await data("service/home/index")["moduleList"] as? [[String: Any]] ?? [])
            .compactMap { row -> (id: Int, type: Int, name: String)? in
                guard let id = Self.int(row["id"]), let type = Self.int(row["type"]), [3, 4, 5, 10, 11].contains(type) else { return nil }
                return (id, type, Self.string(row["name"]))
            }
        return await withTaskGroup(of: (Int, HomeSection?).self) { group in
            for (position, module) in modules.enumerated() {
                group.addTask { @MainActor in
                    guard let data = try? await self.homeModule(module.id) else { return (position, nil) }
                    let title = Self.string(data["moduleName"]).isEmpty ? module.name : Self.string(data["moduleName"])
                    let content: HomeSection.Content
                    switch module.type {
                    case 3, 10: content = .songs((data["musicList"] as? [[String: Any]] ?? []).compactMap(Self.song))
                    case 5: content = .playlists((data["songList"] as? [[String: Any]] ?? []).compactMap { Self.playlist($0) })
                    default: content = .playlists(Self.aiPlaylists(data["songList"] as? [[String: Any]] ?? []))
                    }
                    switch content {
                    case .songs(let items) where items.isEmpty: return (position, nil)
                    case .playlists(let items) where items.isEmpty: return (position, nil)
                    default: return (position, HomeSection(moduleID: module.id, type: module.type, title: title, content: content))
                    }
                }
            }
            var sections: [(Int, HomeSection)] = []
            for await (position, section) in group { if let section { sections.append((position, section)) } }
            return sections.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Each group is one AI playlist; its preview songs supply the cover.
    nonisolated static func aiPlaylists(_ groups: [[String: Any]]) -> [ProviderPlaylist] {
        groups.enumerated().compactMap { position, group in
            let songs = (group["songs"] as? [[String: Any]] ?? []).compactMap(song)
            let title = string(group["title"]).isEmpty ? string(group["passRecName"]) : string(group["title"])
            guard !songs.isEmpty, !title.isEmpty else { return nil }
            let reference = BodianPlaylistReference.ai(index: position, passRecName: string(group["passRecName"]))
            var item = ProviderPlaylist(id: 0, name: title, coverURL: songs.first?.coverURL, trackCount: 30, source: .bodian)
            item.bodian = reference
            return item
        }
    }

    func aiPlaylist(index: Int, passRecName: String) async throws -> (title: String, subtitle: String, songs: [ProviderSong]) {
        let data = try await data("service/home/aiPlaylistDetail", [("index", String(index)), ("passRecName", passRecName)])
        return (Self.string(data["title"]), Self.string(data["subTitle"]),
                (data["musicList"] as? [[String: Any]] ?? []).compactMap(Self.song))
    }

    // MARK: Playlist editing

    func createPlaylist(name: String, isPrivate: Bool) async throws -> ProviderPlaylist {
        let uid = try requireAccount()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderRequestError.unknown("歌单名称不能为空") }
        let json = try await call("/api/service/playlist", body: ["name": trimmed, "private": isPrivate],
                                  method: "POST", signed: true)
        guard let id = Self.idString((json["data"] as? [String: Any])?["id"]) else { throw BodianError.invalidResponse }
        var item = ProviderPlaylist(id: Int(id) ?? 0, name: trimmed, coverURL: nil, source: .bodian)
        item.bodian = BodianPlaylistReference(playlistID: id, source: 5)
        item.ownerID = uid
        item.isOwned = true
        return item
    }

    func deletePlaylist(_ id: String) async throws {
        _ = try requireAccount()
        guard let number = Int64(id) else { throw BodianError.invalidResponse }
        try await call("/api/service/playlist", body: ["playlistIds": [number]], method: "DELETE", signed: true)
    }

    /// The edit endpoint rewrites every field, so the current description,
    /// cover and tags are read back and sent unchanged.
    func renamePlaylist(_ id: String, name: String) async throws -> String {
        _ = try requireAccount()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let number = Int64(id) else { throw ProviderRequestError.unknown("歌单名称不能为空") }
        let info = try await data("service/playlist/info/\(id)", [("source", "5")], signed: true)
        guard Self.idString(info["id"]) == id else { throw MusicProviderError.missingTrack }
        let tags = (info["categories"] as? [[String: Any]] ?? []).compactMap { Self.int($0["id"]) }
        try await call("/api/service/playlist", body: ["id": number, "name": trimmed, "description": Self.string(info["description"]),
                                                       "pic": Self.string(info["pic"]), "categoryList": tags],
                       method: "PUT", signed: true)
        return trimmed
    }

    // MARK: Collections

    enum CollectionKind: Int { case playlist = 4, album = 6, artist = 7 }

    /// `op` names the target state (1 save, 2 remove); following an artist
    /// also carries the session token in the body.
    func setCollected(_ kind: CollectionKind, id: String, source: Int? = nil, saved: Bool) async throws {
        let uid = try requireAccount()
        guard let target = Int64(id), let user = Int64(uid) else { throw BodianError.invalidResponse }
        var body: [String: Any] = ["source": source ?? kind.rawValue, "sourceId": [target], "op": saved ? 1 : 2, "uid": user]
        if kind == .artist { body["token"] = credentials["token"] ?? "" }
        try await call("/api/service/collect", body: body, method: "POST", signed: true)
    }

    func isAlbumCollected(_ id: String) async throws -> Bool? {
        guard isLoggedIn else { return nil }
        let data = try await data("service/collect/multipleState", [("source", "6"), ("sourceIds", id)], signed: true)
        let match = (data["result"] as? [[String: Any]] ?? []).first { Self.idString($0["id"]) == id }
        return match.map { ($0["collect"] as? Bool) ?? (Self.int($0["collect"]) == 1) }
    }

    /// A playlist's info carries `collectTime` only when the account saved it.
    func isPlaylistCollected(_ reference: BodianPlaylistReference) async throws -> Bool {
        guard isLoggedIn, reference.aiIndex == nil, reference.isChart != true else { return false }
        let info = try await data("service/playlist/info/\(reference.playlistID)", [("source", String(reference.source))], signed: true)
        return !Self.string(info["collectTime"]).isEmpty
    }

    func followedArtists() async throws -> [ProviderArtist] {
        let uid = try requireAccount()
        let rows = try await allPages("service/collect/7/list", extra: [("userId", uid), ("fromUid", uid)],
                                      field: "artistList", firstPage: 1, maxItems: 1000)
        return rows.compactMap(Self.artist)
    }

    // MARK: Comments

    nonisolated static let commentPageSize = 30

    /// Comments are served to the Android client headers. Pages are fixed at
    /// 30: smaller sizes come back short (10 returns 5).
    func comments(musicID: String, sort: SongCommentSort, page: Int) async throws -> (comments: [Comment], total: Int, more: Bool) {
        let path = sort == .hot ? "comments/v3/hot" : "comments/v3/new"
        let data = try await data(path, [("moduleType", "2"), ("moduleId", musicID), ("pn", String(max(1, page))),
                                         ("rn", String(Self.commentPageSize))], platform: "android")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let comments = (data["comment_list"] as? [[String: Any]] ?? []).compactMap { row -> Comment? in
            guard let id = Self.int(row["id"]) else { return nil }
            let user = row["userInfo"] as? [String: Any] ?? [:]
            let created = Self.string(row["createTime"])
            formatter.dateFormat = created.count > 10 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
            return Comment(id: id, content: Self.string(row["content"]),
                           nickname: Self.string(row["nickname"]).isEmpty ? Self.string(user["nickname"]) : Self.string(row["nickname"]),
                           avatarURL: Self.coverURL(row["headImg"] ?? user["headImg"]),
                           time: formatter.date(from: created) ?? Date(timeIntervalSince1970: 0),
                           likedCount: Self.int(row["likeCount"]) ?? 0)
        }
        return (comments, Self.int(data["comment_total"]) ?? comments.count, (data["more"] as? Bool) ?? false)
    }

    // MARK: Recently played

    /// The account's synced history (the mobile app's 最近播放), newest first.
    /// Entries carry no play time and the server keeps at most 500.
    func recentPlays(limit: Int = 500) async throws -> [ProviderSong] {
        _ = try requireAccount()
        var songs: [ProviderSong] = []
        var page = 1
        while songs.count < limit {
            let data = try await data("playlist/history/page", [("sourceType", "1"), ("pn", String(page)), ("rn", "200")], signed: true)
            let rows = data["list"] as? [[String: Any]] ?? []
            songs += rows.compactMap(Self.song)
            let total = Self.int(data["total"]) ?? 0
            guard rows.count == 200, page * 200 < total else { break }
            page += 1
        }
        return Array(songs.prefix(limit))
    }

    /// Records one started song, as the mobile app does when playback begins.
    func appendRecentPlay(musicID: String, account: [String: String]) async throws {
        guard Self.validSession(account), let id = Int64(musicID) else { throw BodianError.authRequired }
        try await call("/api/playlist/history/add", body: ["sourceType": 1, "items": [["sourceId": id]]],
                       method: "POST", signed: true, account: account)
    }

    // MARK: Membership

    func membership(credentials: [String: String]) async throws -> MusicMembership {
        guard Self.validSession(credentials), let uid = credentials["userid"] else { return .unknown }
        let data = try await data("ucenter/users/pub/\(uid)", account: credentials, signed: true)
        return MusicMembership.bodian(data["payInfo"] as? [String: Any])
    }
}

extension MusicMembership {
    /// Ordered as the official client: `vipType` 1 is 波点会员 unless the
    /// paid tier is the listening one, otherwise 大会员.
    static func bodian(_ payInfo: [String: Any]?, now: Date = Date()) -> Self {
        guard let payInfo else { return .unknown }
        func number(_ key: String) -> Int { BodianMusicAPI.int(payInfo[key]) ?? 0 }
        func flag(_ key: String) -> Bool { (payInfo[key] as? Bool) == true }
        let member = flag("isVipBoolean") || number("isVip") > 0 || flag("isPayVipBoolean") || flag("isBigVipBoolean")
            || flag("isActVipBoolean") || flag("isBigPayVipBoolean") || flag("isCtVipBoolean")
            || number("vipType") > 0 || number("payVipType") > 0 || number("actVipType") > 0
        guard member else { return .none }
        let expiries = ["expireDate", "payExpireDate", "bigExpireDate", "bigPayExpireDate", "ctExpireDate", "ctPayExpireDate", "actExpireDate"]
            .map { BodianMusicAPI.int(payInfo[$0]) ?? 0 }.filter { $0 > 0 && $0 < 4_102_444_800_000 }
        if let latest = expiries.max(), Date(timeIntervalSince1970: Double(latest) / 1000) <= now { return .none }
        if number("vipType") == 1, number("payVipType") == 2 { return .bodianVIP }
        return .bodianBigVIP
    }
}
