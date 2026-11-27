// Bodian (波点音乐) desktop protocol, ported from bodian-music-api 0.1.2
// (Mintcolour, AGPL-3.0, extracted from chthollyphile/folia-major); see
// ThirdPartyNotices/README.md. Request signing, QR login, catalog paging,
// playback rights and the word-timing lyric decoding follow that package.
import CryptoKit
import Foundation

struct BodianTrackReference: Codable, Hashable, Sendable {
    let musicID: String
    var freeSign: String? = nil
    var albumID: String? = nil
    var artists: [ProviderArtist]? = nil
}

struct BodianPlaylistReference: Codable, Hashable, Sendable {
    let playlistID: String
    /// Bodian's playlist source: 4 public, 5 the account's own lists, 6 album.
    let source: Int
    /// A home-page AI playlist (个性化歌单 / 主题歌单), opened by position.
    var aiIndex: Int? = nil
    var passRecName: String? = nil
    /// A 波波排行榜 chart, whose tracks come from `service/bang/{id}/musics`.
    var isChart: Bool? = nil

    static func ai(index: Int, passRecName: String) -> Self {
        .init(playlistID: "ai:\(index):\(passRecName)", source: 0, aiIndex: index, passRecName: passRecName)
    }
}

enum BodianError: LocalizedError, Equatable {
    case authRequired, regionRestricted(String), notPlayable, previewOnly, business(Int), invalidResponse, qrExpired

    var errorDescription: String? {
        switch self {
        case .authRequired: return "波点音乐登录已失效，请使用波点音乐 App 重新扫码"
        case .regionRestricted(let message): return "\(message)，请检查网络环境"
        case .notPlayable: return "波点音乐暂无此歌曲的播放权限"
        case .previewOnly: return "当前波点账号仅可试听此歌曲"
        case .business(let code): return "波点音乐请求被拒绝（\(code)），请稍后重试"
        case .invalidResponse: return "波点音乐返回了无法识别的数据，请稍后重试"
        case .qrExpired: return "二维码已过期，请刷新"
        }
    }
}

@MainActor
final class BodianMusicAPI {
    static let shared = BodianMusicAPI(persistsSession: true)
    /// Anonymous catalog access for lyric matching on other platforms, so a
    /// lyric search never acts as (or expires) the signed-in Bodian account.
    static let lyricsClient = BodianMusicAPI(deviceID: shared.deviceID)

    static let apiOrigin = "https://bd-api.kuwo.cn"
    static let lyricOrigin = "https://mlyric.kuwo.cn"
    private static let credentialKey = "bodian.session.v1"
    private static let deviceKey = "bodian.device.v1"
    private static let qrLifetime: TimeInterval = 5 * 60

    private let session: URLSession
    private let persistsSession: Bool
    private let now: () -> Date
    let deviceID: String
    private(set) var credentials: [String: String] = [:]
    /// Bumped whenever the session changes, so a late response from the old
    /// account never writes over the new one.
    private(set) var revision = UUID()
    private var pendingQRCodes: [String: (expiresAt: Date, revision: UUID)] = [:]
    /// The active account's 「我喜欢」 list, learned from its library.
    private(set) var favoritesID: String?

    var userID: String { credentials["userid"] ?? "" }
    var nickname: String { credentials["nickname"] ?? "" }
    var avatarURL: String? { credentials["avatar"].flatMap { $0.isEmpty ? nil : $0 } }
    var isLoggedIn: Bool { Self.validSession(credentials) }

    init(configuration: URLSessionConfiguration = .ephemeral, persistsSession: Bool = false,
         deviceID: String? = nil, now: @escaping () -> Date = Date.init) {
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        self.persistsSession = persistsSession
        self.now = now
        if let deviceID { self.deviceID = deviceID }
        else if let saved = ProviderCredentialDefaults.shared.dictionary(forKey: Self.deviceKey)?["id"] as? String,
                Self.validDeviceID(saved) { self.deviceID = saved }
        else {
            let generated = Self.makeDeviceID()
            if persistsSession { ProviderCredentialDefaults.shared.set(["id": generated], forKey: Self.deviceKey) }
            self.deviceID = generated
        }
        if persistsSession, let saved = ProviderCredentialDefaults.shared.dictionary(forKey: Self.credentialKey) as? [String: String],
           Self.validSession(saved) {
            credentials = saved
        }
    }

    // MARK: Session

    nonisolated static func validDeviceID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    nonisolated static func makeDeviceID() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    nonisolated static func validUserID(_ value: String) -> Bool {
        (1...20).contains(value.count) && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) && value.first != "0"
    }

    nonisolated static func validSession(_ value: [String: String]) -> Bool {
        guard let token = value["token"], validUserID(value["userid"] ?? "") else { return false }
        return !token.isEmpty && token.utf8.count <= 4096 && !token.contains { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }
    }

    func restore(_ value: [String: String]) throws {
        guard Self.validSession(value) else { throw BodianError.authRequired }
        if persistsSession, !ProviderCredentialDefaults.shared.set(value, forKey: Self.credentialKey) {
            throw MusicProviderError.storage(ProviderCredentialDefaults.shared.lastError ?? -1)
        }
        if credentials["userid"] != value["userid"] || credentials["token"] != value["token"] { revision = UUID(); favoritesID = nil }
        credentials = value
    }

    func logout() throws {
        if persistsSession {
            ProviderCredentialDefaults.shared.removeObject(forKey: Self.credentialKey)
            if let error = ProviderCredentialDefaults.shared.lastError { throw MusicProviderError.storage(error) }
        }
        credentials = [:]
        pendingQRCodes = [:]
        favoritesID = nil
        revision = UUID()
    }

    /// Drops a session the server rejected, unless the account changed meanwhile.
    private func expire(_ rejected: [String: String]?) {
        guard persistsSession, let rejected, rejected == credentials else { return }
        try? logout()
    }

    // MARK: Transport

    /// The desktop client signs the encoded query (and the exact JSON body, if any).
    nonisolated static func sign(path: String, query: String, body: String = "") -> String {
        var seed = "kuwotest" + String(query.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.sorted())
        if !body.isEmpty { seed += md5(body + "kuwotest") }
        return md5(seed + path)
    }

    nonisolated static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `URLSearchParams` encoding, which the signature is computed over.
    nonisolated static func formEncode(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "*-._")
        func encode(_ value: String) -> String {
            value.split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
                .joined(separator: "+")
        }
        return items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    nonisolated static func headers(deviceID: String) -> [String: String] {
        ["User-Agent": "Dart/3.3 (dart:io)", "plat": "win", "channel": "W1", "ver": "1.1.7",
         "svrver": "13", "api-ver": "application/json", "brand": "Windows", "net": "wifi",
         "devid": deviceID, "qimei36": deviceID, "Content-Type": "application/json"]
    }

    /// Builds one request. Playback endpoints are signed GETs whose parameters
    /// the desktop client also repeats in a JSON body; URLSession cannot send a
    /// GET body, and the query alone carries them, so GETs are signed without it.
    func request(_ path: String, params: [(String, String)] = [], body: [String: Any]? = nil,
                 method: String = "GET", signed: Bool = false, anonymous: Bool = false,
                 lyric: Bool = false, account: [String: String]? = nil, platform: String? = nil) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains("..") else { throw BodianError.invalidResponse }
        let account = anonymous ? nil : (account ?? (isLoggedIn ? credentials : nil))
        var query = params + [("uid", account?["userid"] ?? "-1"), ("token", account?["token"] ?? "")]
        var bodyText = ""
        if let body, method != "GET" {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            bodyText = String(decoding: data, as: UTF8.self)
        }
        if signed {
            query.append(("timestamp", String(Int64(now().timeIntervalSince1970 * 1000))))
            query.append(("sign", Self.sign(path: path, query: Self.formEncode(query), body: bodyText)))
        }
        guard let url = URL(string: (lyric ? Self.lyricOrigin : Self.apiOrigin) + path + "?" + Self.formEncode(query)) else {
            throw BodianError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in Self.headers(deviceID: deviceID) { request.setValue(value, forHTTPHeaderField: key) }
        if let platform { request.setValue(platform, forHTTPHeaderField: "plat") }
        if let account {
            request.setValue(account["userid"], forHTTPHeaderField: "uid")
            request.setValue(account["token"], forHTTPHeaderField: "token")
        }
        if !bodyText.isEmpty { request.httpBody = Data(bodyText.utf8) }
        return request
    }

    @discardableResult
    func call(_ path: String, params: [(String, String)] = [], body: [String: Any]? = nil, method: String = "GET",
              signed: Bool = false, anonymous: Bool = false, lyric: Bool = false,
              account: [String: String]? = nil, platform: String? = nil) async throws -> [String: Any] {
        let used = anonymous ? nil : (account ?? (isLoggedIn ? credentials : nil))
        let request = try request(path, params: params, body: body, method: method, signed: signed,
                                  anonymous: anonymous, lyric: lyric, account: used, platform: platform)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw BodianError.invalidResponse }
        if http.statusCode == 401 { if account == nil { expire(used) }; throw BodianError.authRequired }
        guard (200..<300).contains(http.statusCode) else { throw ProviderRequestError.httpStatus(http.statusCode, "") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BodianError.invalidResponse }
        do { try Self.check(json) }
        catch BodianError.authRequired { if account == nil { expire(used) }; throw BodianError.authRequired }
        return json
    }

    /// The service drops idle keep-alive connections without closing them, so
    /// the first request on a stale connection only fails at the timeout. One
    /// retry on a fresh connection covers it; writes are safe to repeat because
    /// each names its target state (collect `op`, add/remove a track).
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = request
        attempt.timeoutInterval = 8
        do { return try await session.data(for: attempt) }
        catch let error as URLError where Self.retriesOnFreshConnection(error.code) {
            try Task.checkCancellation()
            attempt.timeoutInterval = 15
            return try await session.data(for: attempt)
        }
    }

    nonisolated static func retriesOnFreshConnection(_ code: URLError.Code) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(code)
    }

    nonisolated static func check(_ json: [String: Any]) throws {
        let code = int(json["code"]) ?? -1
        guard code != 200 else { return }
        switch code {
        case 407:
            let message = (json["msg"] as? String ?? json["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw BodianError.regionRestricted(message.isEmpty ? "由于版权保护，该资源仅限中国大陆地区使用" : message)
        case 11012: throw BodianError.authRequired
        case 20018: throw BodianError.notPlayable
        default: throw BodianError.business(code)
        }
    }

    func data(_ path: String, _ params: [(String, String)] = [], account: [String: String]? = nil,
              signed: Bool = false, platform: String? = nil) async throws -> [String: Any] {
        try await call("/api/\(path)", params: params, signed: signed, account: account, platform: platform)["data"] as? [String: Any] ?? [:]
    }

    // MARK: QR login

    struct QRCode { let key: String; let scanURL: URL }
    enum QRStatus: Equatable { case waiting, scanned, expired, confirmed([String: String]) }

    func qrCode() async throws -> QRCode {
        pendingQRCodes = pendingQRCodes.filter { $0.value.expiresAt > now() }
        let json = try await call("/api/ucenter/login/qrCode", signed: true, anonymous: true)
        guard let key = (json["data"] as? [String: Any])?["qrCode"] as? String, !key.isEmpty,
              var components = URLComponents(string: "https://bodian-oia.kuwo.cn/bodian/download.html") else {
            throw BodianError.invalidResponse
        }
        components.queryItems = [.init(name: "pageName", value: "login_pc"), .init(name: "pt", value: "3"), .init(name: "id", value: key)]
        guard let url = components.url else { throw BodianError.invalidResponse }
        pendingQRCodes[key] = (now().addingTimeInterval(Self.qrLifetime), revision)
        return QRCode(key: key, scanURL: url)
    }

    func isQRCodeExpired(_ key: String) -> Bool {
        guard let pending = pendingQRCodes[key] else { return true }
        return pending.expiresAt <= now()
    }

    func cancelLogin(_ key: String? = nil) {
        if let key { pendingQRCodes[key] = nil } else { pendingQRCodes = [:] }
    }

    /// The confirmed credentials are returned, not adopted: the caller decides
    /// whether they replace the active account or join the saved list.
    func pollQRCode(_ key: String) async throws -> QRStatus {
        guard let pending = pendingQRCodes[key], pending.expiresAt > now() else { pendingQRCodes[key] = nil; return .expired }
        let json = try await call("/api/ucenter/login/qrCodeStatus", params: [("qrCode", key)], signed: true, anonymous: true)
        guard pendingQRCodes[key]?.revision == pending.revision else { return .expired }
        switch Self.int((json["data"] as? [String: Any])?["status"]) {
        case 1: return .waiting
        case 2: pendingQRCodes[key] = nil; return .expired
        case 3: break
        default: throw BodianError.invalidResponse
        }
        let login: [String: Any]
        do {
            login = try await call("/api/ucenter/users/login", body: ["authType": 10, "qrCode": key],
                                   method: "POST", signed: true, anonymous: true)["data"] as? [String: Any] ?? [:]
        } catch BodianError.business(11027) { return .scanned }
        guard pendingQRCodes[key]?.revision == pending.revision else { return .expired }
        let credentials = try Self.loginCredentials(login)
        pendingQRCodes = [:]
        return .confirmed(credentials)
    }

    /// Rejects contradictory identities before any credential is accepted.
    nonisolated static func loginCredentials(_ login: [String: Any]) throws -> [String: String] {
        let user = login["userInfo"] as? [String: Any] ?? login["user"] as? [String: Any] ?? [:]
        let ids = [login["id"], login["uid"], user["id"], user["uid"]].compactMap { $0 }.compactMap(idString)
        guard let uid = ids.first, validUserID(uid), ids.allSatisfy({ $0 == uid }),
              let token = login["token"] as? String, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BodianError.invalidResponse
        }
        var credentials = ["userid": uid, "token": token]
        let nickname = string(user["nickname"])
        if !nickname.isEmpty { credentials["nickname"] = nickname }
        let avatar = coverURL(user["headImg"] ?? user["avatarUrl"])?.absoluteString ?? ""
        if !avatar.isEmpty { credentials["avatar"] = avatar }
        guard validSession(credentials) else { throw BodianError.invalidResponse }
        return credentials
    }

    /// The account's 「我喜欢」 list; an authenticated read that also proves the session.
    func favoritesPlaylist(account: [String: String]? = nil) async throws -> ProviderPlaylist? {
        let owner = account ?? credentials
        guard Self.validSession(owner) else { throw BodianError.authRequired }
        let uid = owner["userid"] ?? ""
        let data = try await data("service/playlist/fond", [("userId", uid), ("fromUid", uid)], account: account)
        guard data["id"] != nil else { return nil }
        var item = Self.playlist(data, source: 5, ownerID: uid)
        item?.isOwned = true
        if account == nil, owner == credentials { favoritesID = item?.bodian?.playlistID }
        return item
    }

    func validity(credentials: [String: String]) async throws -> MusicAccountValidity {
        guard Self.validSession(credentials) else { return .invalid }
        do { _ = try await favoritesPlaylist(account: credentials); return .valid }
        catch BodianError.authRequired { return .invalid }
    }

    // MARK: Catalog

    nonisolated static func page(limit: Int, offset: Int, firstPage: Int) -> [(String, String)] {
        let size = min(max(limit, 1), 100)
        return [("pn", String(offset / size + firstPage)), ("rn", String(size))]
    }

    func searchSongs(keyword: String, limit: Int, offset: Int) async throws -> (songs: [ProviderSong], total: Int?) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 500 else { return ([], 0) }
        let data = try await data("search/music/list", [("keyword", keyword), ("correct", "1")]
            + Self.page(limit: limit, offset: offset, firstPage: 0))
        let rows = data["resultList"] as? [[String: Any]] ?? []
        let skip = offset % min(max(limit, 1), 100)
        return (rows.dropFirst(skip).compactMap(Self.song), Self.int(data["total"]))
    }

    /// Server pages may omit unavailable songs, so paging follows the requested
    /// page boundaries and stops on the reported total, not the row count.
    func allPages(_ path: String, extra: [(String, String)] = [], field: String, firstPage: Int,
                          maxItems: Int = 2000) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var page = firstPage
        while rows.count < maxItems {
            let data = try await data(path, extra + [("pn", String(page)), ("rn", "100")])
            let batch = data["resultList"] as? [[String: Any]] ?? data[field] as? [[String: Any]] ?? []
            rows += batch
            let total = Self.int(data["total"])
            let fetched = (page - firstPage + 1) * 100
            guard !batch.isEmpty, total.map({ fetched < $0 }) ?? (batch.count == 100) else { break }
            page += 1
        }
        return rows
    }

    func playlistDetail(_ reference: BodianPlaylistReference) async throws -> (playlist: ProviderPlaylist?, songs: [ProviderSong]) {
        let id = reference.playlistID
        async let info = data("service/playlist/info/\(id)", [("source", String(reference.source))])
        async let rows = allPages("service/playlist/\(id)/musicList", extra: [("source", String(reference.source))],
                                  field: "list", firstPage: 1)
        let (metadata, tracks) = try await (try? info, rows)
        return (metadata.flatMap { Self.playlist($0, source: reference.source) }, tracks.compactMap(Self.song))
    }

    func albumDetail(_ id: String) async throws -> (album: ProviderAlbum?, artist: ProviderArtist?, description: String, songs: [ProviderSong]) {
        async let info = data("service/album/\(id)")
        async let rows = allPages("service/album/music/\(id)", field: "resultList", firstPage: 0)
        let (metadata, tracks) = try await (try? info, rows)
        let album = (metadata?["albumInfo"] as? [String: Any]) ?? metadata
        let artist = album.flatMap { item -> ProviderArtist? in
            let id = Self.idString(item["artistId"]) ?? ""
            let name = Self.string(item["artist"])
            return id.isEmpty || name.isEmpty ? nil : ProviderArtist(id: id, name: name, coverURL: Self.coverURL(item["artistPic"]), source: .bodian)
        }
        return (album.flatMap(Self.album), artist, Self.string(album?["info"]), tracks.compactMap(Self.song))
    }

    func artistDetail(_ id: String) async throws -> (artist: ProviderArtist?, description: String, songs: [ProviderSong]) {
        async let info = data("service/artist/\(id)")
        async let page = data("service/artist/music/\(id)", Self.page(limit: 100, offset: 0, firstPage: 0))
        let (metadata, songs) = try await (try? info, page)
        let artist = (metadata?["artistInfo"] as? [String: Any]).flatMap(Self.artist)
        let rows = songs["resultList"] as? [[String: Any]] ?? []
        return (artist, Self.string((metadata?["artistInfo"] as? [String: Any])?["desc"]), rows.compactMap(Self.song))
    }

    func artistSongs(_ id: String, limit: Int, offset: Int) async throws -> (songs: [ProviderSong], hasMore: Bool) {
        let data = try await data("service/artist/music/\(id)", Self.page(limit: limit, offset: offset, firstPage: 0))
        let rows = data["resultList"] as? [[String: Any]] ?? []
        let total = Self.int(data["total"])
        let end = (offset / min(max(limit, 1), 100) + 1) * min(max(limit, 1), 100)
        return (rows.compactMap(Self.song), !rows.isEmpty && (total.map { end < $0 } ?? (rows.count == limit)))
    }

    func artistAlbums(_ id: String, limit: Int, offset: Int) async throws -> (albums: [ProviderAlbum], hasMore: Bool) {
        let data = try await data("service/artist/album/\(id)", Self.page(limit: limit, offset: offset, firstPage: 0))
        let rows = data["resultList"] as? [[String: Any]] ?? []
        let total = Self.int(data["total"])
        let end = (offset / min(max(limit, 1), 100) + 1) * min(max(limit, 1), 100)
        return (rows.compactMap(Self.album), !rows.isEmpty && (total.map { end < $0 } ?? (rows.count == limit)))
    }

    func recommendedPlaylists(limit: Int) async throws -> [ProviderPlaylist] {
        let data = try await data("service/finds/playlist")
        let groups = data["lists"] as? [[String: Any]] ?? []
        let rows = groups.flatMap { $0["playLists"] as? [[String: Any]] ?? [] }
        var seen = Set<String>()
        return rows.compactMap { Self.playlist($0) }.filter { seen.insert($0.bodian?.playlistID ?? "").inserted }.prefix(limit).map { $0 }
    }

    /// The home page's "treasure" playlists (module 2) and "heart-flutter" singles (module 3).
    func homeModule(_ id: Int) async throws -> [String: Any] {
        try await data("service/home/module", [("moduleId", String(id))])
    }

    func homePlaylists() async throws -> [ProviderPlaylist] {
        let rows = try await homeModule(2)["songList"] as? [[String: Any]] ?? []
        return rows.compactMap { Self.playlist($0) }
    }

    func homeSongs() async throws -> [ProviderSong] {
        (try await homeModule(3)["musicList"] as? [[String: Any]] ?? []).compactMap(Self.song)
    }

    func personalFM() async throws -> [ProviderSong] {
        (try await data("service/music/recommendList")["musicList"] as? [[String: Any]] ?? []).compactMap(Self.song)
    }

    // MARK: Library

    func requireAccount() throws -> String {
        guard isLoggedIn else { throw BodianError.authRequired }
        return userID
    }

    func userPlaylists() async throws -> [ProviderPlaylist] {
        let uid = try requireAccount()
        let user = [("userId", uid), ("fromUid", uid)]
        async let owned = data("service/playlist/userCreate", user)
        async let liked = favoritesPlaylist()
        async let collected = allPages("service/collect/4/list", extra: user, field: "playLists", firstPage: 1, maxItems: 1000)
        let (own, favorite, rows) = try await (owned, liked, collected)
        var lists: [ProviderPlaylist] = []
        if let favorite { lists.append(favorite) }
        lists += (own["playLists"] as? [[String: Any]] ?? []).compactMap {
            var item = Self.playlist($0, source: 5, ownerID: uid)
            item?.isOwned = true
            return item
        }
        let ownIDs = Set(lists.compactMap { $0.bodian?.playlistID })
        lists += rows.filter { Self.int($0["sourceType"]) != 6 }.compactMap { row -> ProviderPlaylist? in
            guard var item = Self.playlist(row), !ownIDs.contains(item.bodian?.playlistID ?? "") else { return nil }
            item.isSubscribed = true
            return item
        }
        return lists
    }

    func collectedAlbums() async throws -> [ProviderAlbum] {
        let uid = try requireAccount()
        let rows = try await allPages("service/collect/4/list", extra: [("userId", uid), ("fromUid", uid)],
                                      field: "playLists", firstPage: 1, maxItems: 1000)
        return rows.filter { Self.int($0["sourceType"]) == 6 }.compactMap(Self.album)
    }

    private func updatePlaylist(_ playlistID: String, musicIDs: [String], remove: Bool) async throws {
        let account = credentials
        guard Self.validSession(account) else { throw BodianError.authRequired }
        let tracks = Array(Set(musicIDs.compactMap { Int64($0) })).sorted()
        guard let list = Int64(playlistID), !tracks.isEmpty, tracks.count <= 100 else { throw BodianError.invalidResponse }
        try await call("/api/service/playlist/music\(remove ? "/delete" : "")",
                       body: ["playListId": list, "musicIdList": tracks], method: "POST", signed: true, account: account)
    }

    /// Only lists the current account owns (its own lists and 「我喜欢」) accept edits.
    func editPlaylist(_ playlistID: String, musicIDs: [String], adding: Bool) async throws {
        let uid = try requireAccount()
        let own = try await data("service/playlist/userCreate", [("userId", uid), ("fromUid", uid)])
        let owned = (own["playLists"] as? [[String: Any]] ?? []).contains { Self.idString($0["id"]) == playlistID }
        if !owned, try await favoritesPlaylist()?.bodian?.playlistID != playlistID { throw MusicProviderError.unsupported }
        try await updatePlaylist(playlistID, musicIDs: musicIDs, remove: !adding)
    }

    func setLiked(musicID: String, liked: Bool) async throws {
        guard let favorites = try await favoritesPlaylist(), let id = favorites.bodian?.playlistID else {
            throw ProviderRequestError.unknown("未找到波点音乐「我喜欢」歌单，请刷新音乐库后重试")
        }
        try await updatePlaylist(id, musicIDs: [musicID], remove: !liked)
    }

    // MARK: Playback

    struct PlaybackResource { let url: String; let format: String; let bitrate: Int; let quality: AudioQuality; let durationMS: Int }

    nonisolated static func format(for quality: AudioQuality?) -> (format: String, br: String, quality: AudioQuality) {
        switch quality {
        case .standard?, .higher?: return ("mp3", "128kmp3", .standard)
        case .exhigh?: return ("mp3", "320kmp3", .exhigh)
        default: return ("flac", "2000kflac", .lossless)
        }
    }

    func playback(_ reference: BodianTrackReference, quality: AudioQuality?) async throws -> PlaybackResource {
        let id = reference.musicID
        let freeSign = String((reference.freeSign ?? "").prefix(4096))
        let right = try await call("/api/play/music/v2/checkRight", params: [("musicId", id), ("freeSign", freeSign)],
                                   signed: true)["data"] as? [String: Any]
        switch Self.int(right?["status"]) {
        case 3?: throw BodianError.previewOnly
        case 7?: throw isLoggedIn ? BodianError.notPlayable : BodianError.authRequired
        case nil: throw isLoggedIn ? BodianError.notPlayable : BodianError.authRequired
        default: break
        }
        let requested = Self.format(for: quality)
        let audio = try await call("/api/play/music/v2/audioUrl", params: [("devId", deviceID), ("musicId", id),
            ("format", requested.format), ("br", requested.br), ("freeSign", freeSign)], signed: true)["data"] as? [String: Any] ?? [:]
        let address = Self.string(audio["audioHttpsUrl"]).isEmpty ? Self.string(audio["audioUrl"]) : Self.string(audio["audioHttpsUrl"])
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), url.user == nil else {
            throw BodianError.invalidResponse
        }
        let format = Self.string(audio["format"]).lowercased()
        let bitrate = Self.int(audio["bitrate"]) ?? 0
        // The server falls back silently; report what it actually served.
        let served: AudioQuality = format == "flac" ? .lossless : bitrate >= 320 ? .exhigh : .standard
        return PlaybackResource(url: address, format: format, bitrate: bitrate * 1000, quality: served,
                                durationMS: (Self.int(audio["duration"]) ?? 0) * 1000)
    }

    // MARK: Lyrics

    func lyric(musicID: String) async throws -> LyricResponse {
        guard Self.idString(musicID) != nil else { throw MusicProviderError.missingTrack }
        let query = "type=lyric&req=2&lrcx=1&rid=\(musicID)&songname=&artist=&corp=kuwo&fromchannel=bodian"
        let json = try await call("/mobi.s", params: [("f", "bodian"), ("q", Data(query.utf8).base64EncodedString())],
                                  anonymous: true, lyric: true)
        guard let content = (json["data"] as? [String: Any])?["content"] as? String else { throw BodianError.invalidResponse }
        let text = Data(base64Encoded: content).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Self.lyricResponse(text)
    }

    /// Bodian obfuscates each word's `<offset,duration>` pair with factors
    /// stored as an octal `[kuwo:NN]` tag: start = |a+b|/(2·s), duration = |a−b|/(2·d).
    nonisolated static func decodeWordTiming(_ a: Int, _ b: Int, factors: Int) -> (start: Int, duration: Int)? {
        let startFactor = factors / 10, durationFactor = factors % 10
        guard startFactor != 0, durationFactor != 0 else { return nil }
        return (abs((a + b) / (2 * startFactor)), abs((a - b) / (2 * durationFactor)))
    }

    nonisolated static func lyricResponse(_ content: String) -> LyricResponse {
        let factors = content.firstMatch(of: #/\[kuwo:([0-7]+)\]/#).flatMap { Int($0.output.1, radix: 8) } ?? 11
        var lrc: [String] = [], translation: [String] = [], yrc: [String] = []
        var seenTimes = Set<Int>()
        var wordTiming = true
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: #/^\[(\d+):(\d+(?:\.\d+)?)\]/#),
                  let minutes = Int(head.output.1), let seconds = Double(head.output.2) else { continue }
            let start = minutes * 60_000 + Int((seconds * 1000).rounded())
            let body = String(line[head.range.upperBound...])
            let words = body.matches(of: #/<(-?\d+),(-?\d+)>([^<]*)/#)
            let plain = words.isEmpty ? body : words.map { String($0.output.3) }.joined()
            let stamp = String(line[head.range])
            // A repeated timestamp carries that line's translation.
            if !seenTimes.insert(start).inserted {
                if !plain.trimmingCharacters(in: .whitespaces).isEmpty { translation.append(stamp + plain) }
                continue
            }
            lrc.append(stamp + plain)
            guard wordTiming, !words.isEmpty else { if words.isEmpty && !plain.isEmpty { wordTiming = false }; continue }
            var timed: [String] = []
            var end = start
            for word in words {
                guard let a = Int(word.output.1), let b = Int(word.output.2),
                      let timing = decodeWordTiming(a, b, factors: factors) else { wordTiming = false; break }
                timed.append("(\(start + timing.start),\(timing.duration),0)\(word.output.3)")
                end = max(end, start + timing.start + timing.duration)
            }
            if wordTiming, !timed.isEmpty { yrc.append("[\(start),\(end - start)]\(timed.joined())") }
        }
        let text = lrc.joined(separator: "\n")
        let empty = LyricsParser.parseLRC(text).allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return LyricResponse(lrc: .init(lyric: text), tlyric: translation.isEmpty ? nil : .init(lyric: translation.joined(separator: "\n")),
                             romalrc: nil, yrc: wordTiming && !yrc.isEmpty ? .init(lyric: yrc.joined(separator: "\n")) : nil,
                             ytlrc: nil, yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: empty, uncollected: nil)
    }

    // MARK: Normalization

    nonisolated static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    nonisolated static func string(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return ""
        }
    }

    /// A positive numeric id of up to 20 digits.
    nonisolated static func idString(_ value: Any?) -> String? {
        let text: String
        if let number = value as? NSNumber {
            guard CFNumberIsFloatType(number) == false else { return nil }
            text = number.stringValue
        } else { text = string(value) }
        return validUserID(text) ? text : nil
    }

    /// Single-level `*.kuwo.cn` hosts serve the same image over HTTPS; nested
    /// CDN hosts are not covered by the certificate and stay as returned.
    nonisolated static func coverURL(_ value: Any?) -> URL? {
        var text = string(value)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("http://"), text.firstMatch(of: #/^http://[\w-]+\.kuwo\.cn//#) != nil {
            text = "https://" + text.dropFirst("http://".count)
        }
        return URL(string: text)
    }

    nonisolated static func artists(_ item: [String: Any]) -> [ProviderArtist] {
        let rows = item["artists"] as? [[String: Any]] ?? [["id": item["artistId"] as Any, "name": item["artist"] as Any]]
        return rows.compactMap { row in
            let name = string(row["name"])
            guard !name.isEmpty else { return nil }
            return ProviderArtist(id: idString(row["id"]) ?? "", name: name, coverURL: coverURL(row["pic"]), source: .bodian)
        }
    }

    nonisolated static func song(_ item: [String: Any]) -> ProviderSong? {
        guard let id = idString(item["id"]), let number = Int(id) else { return nil }
        let title = string(item["songName"]).isEmpty ? string(item["name"]) : string(item["songName"])
        let credits = artists(item)
        let freeSign = string(item["freeSign"]).isEmpty ? string(item["fsig"]) : string(item["freeSign"])
        let reference = BodianTrackReference(musicID: id, freeSign: freeSign.isEmpty ? nil : freeSign,
                                             albumID: idString(item["albumId"]), artists: credits.isEmpty ? nil : credits)
        let fee = (item["payInfo"] as? [String: Any]).map { int($0["paytype"]) ?? 0 } ?? 0
        return ProviderSong(id: number, name: title,
                            artists: credits.isEmpty ? string(item["artist"]) : credits.map(\.name).joined(separator: " / "),
                            album: string(item["album"]), coverURL: coverURL(item["albumPic"]),
                            duration: TimeInterval(max(0, int(item["duration"]) ?? 0)), source: .bodian,
                            bodian: reference, fee: fee)
    }

    nonisolated static func playlist(_ item: [String: Any], source: Int? = nil, ownerID: String? = nil) -> ProviderPlaylist? {
        guard let id = idString(item["id"]) else { return nil }
        let resolved = source ?? int(item["sourceType"]) ?? 4
        var playlist = ProviderPlaylist(id: Int(id) ?? 0, name: string(item["name"]), coverURL: coverURL(item["pic"]),
                                        trackCount: int(item["musicCount"]) ?? int(item["musicCnt"]) ?? 0, source: .bodian)
        playlist.bodian = BodianPlaylistReference(playlistID: id, source: resolved)
        playlist.ownerID = ownerID ?? idString(item["creatorId"])
        return playlist
    }

    nonisolated static func album(_ item: [String: Any]) -> ProviderAlbum? {
        guard let id = idString(item["albumId"]) ?? idString(item["id"]) else { return nil }
        let credits = artists(item)
        let date = string(item["showtime"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return ProviderAlbum(id: id, name: string(item["name"]),
                             artistName: credits.isEmpty ? string(item["artist"]) : credits.map(\.name).joined(separator: " / "),
                             coverURL: coverURL(item["pic"]), source: .bodian,
                             trackCount: int(item["musicCount"]),
                             releaseDateMS: formatter.date(from: date).map { Int($0.timeIntervalSince1970 * 1000) })
    }

    nonisolated static func artist(_ item: [String: Any]) -> ProviderArtist? {
        guard let id = idString(item["id"]) else { return nil }
        return ProviderArtist(id: id, name: string(item["name"]), coverURL: coverURL(item["pic"]), source: .bodian)
    }
}
