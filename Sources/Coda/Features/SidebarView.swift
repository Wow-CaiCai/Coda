import SwiftUI

enum SidebarLayout {
    static let outerInset: CGFloat = 8
    static let rowInset: CGFloat = 16
    static let rowPadding: CGFloat = 12
    static let contentInset = rowInset + rowPadding
    static let hitSize: CGFloat = 44
}

struct SidebarView: View {
    @Binding var selection: SidebarItem
    var onSearchSelected: () -> Void = {}

    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var accountManager = MusicAccountManager.shared
    @ScaledMetric(relativeTo: .headline) private var identityTextSize: CGFloat = 14
    @ScaledMetric(relativeTo: .title2) private var sectionTextSize: CGFloat = 20
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    @ViewBuilder
    private var sections: some View {
        Group {
            SidebarSection {
                row(.home, title: "推荐", icon: "house.fill")
                row(.explore, title: "精选", icon: "square.grid.2x2.fill")
                row(.search, title: "搜索", icon: "magnifyingglass")
                row(.account, title: "账户", icon: "person.crop.circle")
            } header: {
                sectionTitle("音乐")
            }

            if !account.hasAuthCookie && account.provider.supports(.downloads) {
                SidebarSection {
                    row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                } header: {
                    sectionTitle("我的")
                }
            }
            if account.hasAuthCookie {
                SidebarSection {
                    if account.provider == .netease || account.likedSongsPlaylist != nil {
                        row(.likedSongs, title: "我喜欢的音乐", icon: "heart.fill")
                    }
                    if account.provider.supports(.downloads) {
                        row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                    }
                    if account.provider.supports(.recentPlays) {
                        row(.recents, title: "最近播放", icon: "clock.fill")
                    }
                    if account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists) {
                        row(.collections, title: "我的收藏", icon: "star.fill")
                    }
                    if account.provider.supports(.cloud) {
                        row(.cloud, title: "音乐云盘", icon: "icloud.fill")
                    }
                } header: {
                    sectionTitle("我的")
                }

                if !account.createdPlaylists.isEmpty || account.provider.supports(.playlistCreation) {
                    SidebarSection {
                        ForEach(account.createdPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            sectionTitle(LocalizedStringKey(account.provider.playlistSectionTitle))
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: SidebarLayout.hitSize, height: SidebarLayout.hitSize)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("新建歌单")
                            .disabled(!account.provider.supports(.playlistCreation))
                        }
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    SidebarSection {
                        ForEach(account.subscribedPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    } header: {
                        sectionTitle("收藏的歌单")
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                platformMenu
                Spacer(minLength: 0)
                settingsButton
            }
            .padding(.leading, SidebarLayout.contentInset)
            .padding(.trailing, SidebarLayout.rowInset)
            .frame(minHeight: 56)
            .padding(.top, 8)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    sections
                }
                .padding(.horizontal, SidebarLayout.rowInset)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .tint(Theme.accent)
#if os(macOS)
        // Unlike .hidden, .never also applies when a mouse is connected.
        .scrollIndicators(.never)
#endif
        .panelRefresh(key: "sidebar-library") { await account.refreshLibrary(force: $0) }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }

    /// Platforms follow accounts: switching the account switches the platform.
    private var platformMenu: some View {
        Menu {
            ForEach(accountManager.accounts) { item in
                Button { selectAccount(item) } label: {
                    if accountManager.currentID == item.id {
                        Label("\(item.nickname) · \(item.provider.name)", systemImage: "checkmark")
                    } else {
                        Text("\(item.nickname) · \(item.provider.name)")
                    }
                }
            }
            // Platforms without any signed-in account appear inline as guest entries.
            ForEach(guestProviders) { provider in
                Button { browseAsGuest(provider) } label: {
                    if accountManager.isBrowsingAsGuest(provider) {
                        Label("游客 · \(provider.name)", systemImage: "checkmark")
                    } else {
                        Text("游客 · \(provider.name)")
                    }
                }
            }
        } label: {
            platformMenuLabel
        }
        #if os(macOS)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .disabled(accountManager.isSwitching)
        .accessibilityLabel("切换账号")
        .accessibilityValue(Text(account.provider.name))
        .accessibilityIdentifier("sidebarPlatformMenu")
    }

    private var guestProviders: [MusicProvider] {
        let signedIn = Set(accountManager.accounts.map(\.provider))
        return MusicProvider.allCases.filter { !signedIn.contains($0) || accountManager.isBrowsingAsGuest($0) }
    }

    private var platformMenuLabel: some View {
        HStack(spacing: 10) {
            appLogo
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(account.provider.name)
                    .font(.system(size: identityTextSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Group {
                    if accountManager.isSwitching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: SidebarLayout.hitSize)
        .contentShape(Rectangle())
    }

    private func browseAsGuest(_ provider: MusicProvider) {
        Task {
            do {
                try await accountManager.browseAsGuest(provider)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func selectAccount(_ item: MusicAccount) {
        Task {
            do {
                try await accountManager.select(item)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var appLogo: Image {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
        Image("CodaLogo")
        #endif
    }

    private var settingsButton: some View {
        Button { selection = .settings } label: { settingsIcon }
        .buttonStyle(SidebarSettingsButtonStyle())
        .tint(Theme.accent)
        .accessibilityLabel("设置")
        .accessibilityIdentifier("sidebarSettingsButton")
    }

    private var settingsIcon: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 16))
            .frame(width: SidebarLayout.hitSize, height: 56)
            .contentShape(Rectangle())
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: sectionTextSize, weight: .bold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SidebarItem, title: LocalizedStringKey, icon: String) -> some View {
        SidebarRow(title: Text(title), iconSize: 22, isSelected: selection == item) {
            selection = item
            if item == .search { onSearchSelected() }
        } icon: {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.accent)
        }
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        let iconSize: CGFloat = 24
        return SidebarRow(title: Text(playlist.name), iconSize: iconSize, isSelected: selection == .playlist(playlist.id)) {
            selection = .playlist(playlist.id)
        } icon: {
            PlaylistArtwork(playlist: playlist, pixelSize: 64, animated: false)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            Button("播放") {
                Task {
                    if let detail = try? await NeteaseAPI.playlistDetail(id: playlist.id) {
                        await playPlaylist(detail)
                    }
                }
            }
            Divider()
            if playlist.creator?.userId == account.profile?.userId, account.provider.supports(.playlistDeletion), !playlist.isLikedSongsList {
                Button("删除歌单", role: .destructive) {
                    Task {
                        do {
                            try await NeteaseAPI.deletePlaylist(id: playlist.id)
                            if selection == .playlist(playlist.id) { selection = .home }
                            await account.refreshLibrary()
                        } catch { ToastCenter.shared.show("删除失败：\(error.localizedDescription)") }
                    }
                }
            } else if playlist.creator?.userId != account.profile?.userId, account.provider.supports(.playlistSubscriptions) {
                Button("取消收藏") {
                    Task {
                        do {
                            try await NeteaseAPI.subscribePlaylist(id: playlist.id, subscribe: false)
                            await account.refreshLibrary()
                        } catch { ToastCenter.shared.show("取消收藏失败：\(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    private func playPlaylist(_ detail: NeteaseAPI.PlaylistDetailResponse) async {
        var tracks = detail.playlist.tracks
        if tracks.count < detail.playlist.trackCount {
            let ids = detail.playlist.trackIds.map(\.id)
            if let full = try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(1000))) {
                tracks = full.songs
            }
        }
        PlayerService.shared.play(tracks: tracks, source: .playlist(detail.playlist.id))
    }

}

private struct SidebarSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .frame(width: SidebarLayout.hitSize, height: SidebarLayout.hitSize)
            }
    }
}

private struct SidebarSection<Content: View, Header: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, SidebarLayout.rowPadding)
            VStack(spacing: 2, content: content)
        }
    }
}

private struct SidebarRow<Icon: View>: View {
    let title: Text
    let iconSize: CGFloat
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarLayout.rowPadding) {
                icon()
                    .frame(width: iconSize * iconScale, height: iconSize * iconScale)
                    .accessibilityHidden(true)
                title
                    .font(.system(size: textSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SidebarLayout.rowPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: SidebarLayout.hitSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : isSelected ? 0.10 : 0))
            }
    }
}

struct AccountDetailsView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @Environment(\.openDestination) private var openDestination
    private var layout = ProfileDetailLayout()
    @State private var detailRefresh = PanelRefreshGate()
    @State private var recordsRefresh = PanelRefreshGate()
    @State private var displayedAccount: String?
    @State private var displayedRecordsKey = ""
    @State private var statisticsRevision = 0
    @State private var week = true
    @State private var qqRankPeriod = 2
    @State private var records: [PlayRecordItem] = []
    @State private var isLoadingRecords = false
    @State private var recordError: String?
    @State private var detail: NeteaseAPI.UserDetailResponse?
    @State private var detailFailed = false
    @State private var isLoadingCollections = true

    private let rankingOnly: Bool

    init(rankingOnly: Bool = false) { self.rankingOnly = rankingOnly }

    var body: some View {
        Group {
            if let profile = account.profile {
                ProfileDetailPage(artworkBackdropURL: profile.avatarUrl, usesArtworkBackdrop: true) {
                    if !rankingOnly {
                        profileHeader(profile)
                            .accessibilityIdentifier("accountPageHeader")
                    }
                    if account.provider.supports(.playRanking) {
                        rankingHeader.padding(.horizontal, layout.contentInset)
                        rankingSongs
                    }
                    if !rankingOnly {
                        playlistSection(LocalizedStringKey(account.provider.playlistSectionTitle), section: .createdPlaylists,
                                        playlists: account.createdPlaylists)
                        if account.provider.supports(.playlistSubscriptions) {
                            playlistSection("收藏的歌单", section: .subscribedPlaylists, playlists: account.subscribedPlaylists)
                        }
                        if account.provider.supports(.collectionAlbums) { collectedAlbumsSection }
                        if account.provider.supports(.collectionArtists) { collectedArtistsSection }
                    }
                    PlayerClearanceSpacer()
                }
                .id(profile.userId)
                .accessibilityIdentifier("accountProfileScroll")
            } else {
                #if os(iOS)
                ProfileDetailPage(usesArtworkBackdrop: true) {
                    PlaylistDetailHero(artworkURL: nil, title: String(localized: "账户"),
                                           subtitle: String(localized: "登录\(account.provider.name)"), avatarURL: nil,
                                           metadataText: String(localized: "同步我喜欢的音乐、歌单与收藏"),
                                           circularArtwork: true, showsAvatar: false) {
                        profileActions
                    }
                    if account.provider.supports(.accountSync) {
                        SyncedLoginButtons().padding(.horizontal, layout.contentInset)
                    }
                    PlayerClearanceSpacer()
                }
                #else
                VStack(spacing: Theme.Spacing.section) {
                    Label("登录后查看账户信息", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Button("登录\(account.provider.name)", action: openLogin)
                        .buttonStyle(.borderedProminent)
                    if account.provider.supports(.accountSync) { SyncedLoginButtons() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        #if os(macOS)
        .navigationTitle("账户")
        #else
        .navigationTitle(rankingOnly ? "播放排行" : "")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .panelDataChanged)) { _ in
            // Playback reports invalidate statistics even inside their normal cache lifetime.
            statisticsRevision += 1
        }
        .panelRefresh(key: "account:\(week):\(qqRankPeriod):\(account.libraryRevision):\(statisticsRevision)") { force in
            if displayedAccount != MusicProviderContext.shared.authenticationKey {
                displayedAccount = MusicProviderContext.shared.authenticationKey
                detail = nil; records = []; detailFailed = false
                detailRefresh.invalidate(); recordsRefresh.invalidate()
            }
            async let profile: Void = loadDetail(force: force)
            async let ranking: Void = loadRecords(force: force)
            await account.refreshLibrary(force: force)
            isLoadingCollections = account.likedAlbums.isEmpty && account.likedArtists.isEmpty
            await account.refreshSublists(force: force)
            isLoadingCollections = false
            _ = await (profile, ranking)
        }
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        ProfileDetailHeader(imageURL: profile.avatarUrl, title: profile.nickname, category: "账户") {
            if let signature = profile.signature, !signature.isEmpty {
                Text(signature)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    listeningStatistics
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    listeningStatistics
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            Text("用户 ID \(account.displayUserID)")
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let stats = detail?.profile {
                Text("\(stats.follows?.formatted() ?? "—") 关注 · \(stats.followeds?.formatted() ?? "—") 粉丝 · \(stats.playlistCount?.formatted() ?? "—") 歌单")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if detailFailed {
                Button("账户统计加载失败，点此重试") {
                    Task { await loadDetail() }
                }
                .font(Theme.Typography.caption)
            }
        } actions: {
            profileActions
        }
    }

    private var profileActions: some View {
        let hasProfile = account.profile != nil
        return PlaylistPrimaryActions(
            isSaved: false, canSave: hasProfile && account.provider.supports(.cloud),
            canPlay: !hasProfile || (account.provider.supports(.playRanking) ? !records.isEmpty && !isLoadingRecords : account.likedSongsPlaylist != nil),
            isSaving: false,
            onToggleSaved: { openDestination(.cloud) },
            onPlayAll: {
                if !hasProfile { openLogin() }
                else if account.provider.supports(.playRanking) { playRecords() }
                else if let liked = account.likedSongsPlaylist { openDestination(.playlist(liked.id)) }
            },
            leadingIcon: "icloud.fill",
            primaryTitle: hasProfile ? (account.provider.supports(.playRanking) ? "播放排行" : "我喜欢的音乐") : "登录",
            primaryIcon: hasProfile ? "play.fill" : "person.crop.circle",
            showsSaveButton: hasProfile && account.provider.supports(.cloud),
            saveAccessibilityLabel: String(localized: "云盘"),
            saveAccessibilityIdentifier: "accountCloud"
        ) {
            Menu {
                if hasProfile && account.provider.supports(.recentPlays) {
                    Button { openDestination(.recents) } label: {
                        Label("最近播放", systemImage: "clock.fill")
                    }
                }
                if hasProfile && (account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists)) {
                    Button { openDestination(.collections) } label: {
                        Label("我的收藏", systemImage: "star")
                    }
                }
                if account.provider.supports(.downloads) {
                    Button { openDestination(.downloaded) } label: { Label("下载", systemImage: "arrow.down.circle.fill") }
                }
                if account.isLoggedIn {
                    Button("退出登录", role: .destructive) {
                        Task {
                            do { try await account.logout() }
                            catch { ToastCenter.shared.show(error.localizedDescription) }
                        }
                    }
                }
            } label: { PlaylistMoreLabel() }
            .accessibilityLabel("账户选项")
            .accessibilityIdentifier("accountMoreActions")
        }
    }

    @ViewBuilder
    private var listeningStatistics: some View {
        if !account.provider.supports(.profileStatistics) { Text(account.provider.name) }
        if let level = detail?.level {
            Text("Lv.\(level)")
        }
        if let count = detail?.listenSongs {
            Text("累计听歌 \(count.formatted()) 首")
        }
    }

    private var usesVerticalRanking: Bool {
        #if os(iOS)
        rankingOnly || UIDevice.current.userInterfaceIdiom == .phone
        #else
        rankingOnly
        #endif
    }

    private func accountModuleAction(_ destination: Destination) -> (() -> Void)? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad, !rankingOnly else { return nil }
        return { openDestination(destination) }
        #else
        return nil
        #endif
    }

    private var rankingHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.component) {
                SectionHeader(title: "听歌排行", action: accountModuleAction(.playRanking))
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                rankingPeriodPicker
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.control) {
                SectionHeader(title: "听歌排行", action: accountModuleAction(.playRanking))
                rankingPeriodPicker
            }
        }
    }

    @ViewBuilder
    private var rankingPeriodPicker: some View {
        if account.provider == .qq {
            Picker("排行时间", selection: $qqRankPeriod) {
                Text("日").tag(1)
                Text("周").tag(2)
                Text("月").tag(3)
                Text("年").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        } else {
            Picker("排行时间", selection: $week) {
                Text("最近一周").tag(true)
                Text("全部时间").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    @ViewBuilder
    private var rankingSongs: some View {
        if isLoadingRecords {
            ProgressView("正在加载排行")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let recordError {
            ErrorStateView(message: recordError) { Task { await loadRecords() } }
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if records.isEmpty {
            EmptyStateView(icon: "chart.bar.xaxis", title: "暂无听歌排行")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            let playCounts = Dictionary(records.map { ($0.song.id, $0.playCount) },
                                        uniquingKeysWith: { first, _ in first })
            MusicTrackPanel(tracks: records.map(\.song), scrollsHorizontally: !usesVerticalRanking,
                            context: .recents, showsRowSeparators: false, trailingText: { track in
                playCounts[track.id].map { String(localized: "\($0) 次") }
            })
            .accessibilityIdentifier("accountRankingScroll")
        }
    }

    private func playlistSection(_ title: LocalizedStringKey, section: LibrarySection, playlists: [PlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            SectionHeader(title: title, subtitle: "\(playlists.count)",
                          action: accountModuleAction(.librarySection(section)))
                .padding(.horizontal, layout.contentInset)
            if playlists.isEmpty {
                Text("暂无歌单")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, layout.contentInset)
                    .padding(.vertical, Theme.Spacing.control)
            } else {
                ProfileDetailCoverShelf(itemCount: playlists.count, resetKey: playlists.first?.id) { visibleCount in
                    ForEach(playlists.prefix(visibleCount)) { playlist in
                        Button {
                            openDestination(.playlist(playlist.id))
                        } label: {
                            PlaylistCoverCard(playlist: playlist,
                                              subtitle: String(localized: "\(playlist.trackCount) 首歌曲"))
                        }
                        .buttonStyle(.interactiveCard)
                    }
                }
            }
        }
    }

    private var collectedAlbumsSection: some View {
        collectionSection("收藏的专辑", section: .albums, count: account.likedAlbums.count, emptyMessage: "还没有收藏专辑") { visibleCount in
            ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                Button {
                    openDestination(.album(album.id))
                } label: {
                    CoverCardBody(
                        coverURL: album.picUrl?.resizedImageURL(384),
                        title: album.name,
                        subtitle: album.artistName
                    )
                }
                .buttonStyle(.interactiveCard)
            }
        }
    }

    private var collectedArtistsSection: some View {
        collectionSection("收藏的歌手", section: .artists, count: account.likedArtists.count, emptyMessage: "还没有收藏歌手") { visibleCount in
            ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                Button {
                    openDestination(.artist(artist.id))
                } label: {
                    ProfileDetailArtistCardBody(artist: artist)
                }
                .buttonStyle(.interactiveCard)
            }
        }
    }

    private func collectionSection<Content: View>(
        _ title: LocalizedStringKey, section: LibrarySection, count: Int, emptyMessage: LocalizedStringKey,
        @ViewBuilder content: @escaping (Int) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            SectionHeader(title: title, subtitle: "\(count)",
                          action: accountModuleAction(.librarySection(section)))
                .padding(.horizontal, layout.contentInset)
            if count == 0 {
                if isLoadingCollections {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Group {
                        if let error = account.sublistsError { Text(error) } else { Text(emptyMessage) }
                    }
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, layout.contentInset)
                        .padding(.vertical, Theme.Spacing.control)
                }
            } else {
                ProfileDetailCoverShelf(itemCount: count, content: content)
            }
        }
    }

    @MainActor
    private func loadDetail(force: Bool = true) async {
        guard account.provider.supports(.profileStatistics), let uid = account.authenticatedAccountID else { return }
        guard let ticket = detailRefresh.begin(key: "\(uid):\(SidebarResources.playbackRevision):\(statisticsRevision)", lifetime: 60, force: force) else { return }
        var success = false
        defer { detailRefresh.finish(ticket, success: success) }
        do {
            let fetched = try await NeteaseAPI.userDetail(uid: uid)
            guard detailRefresh.accepts(ticket), account.authenticatedAccountID == uid else { return }
            detail = fetched
            detailFailed = false
            success = true
        } catch {
            guard detailRefresh.accepts(ticket), account.authenticatedAccountID == uid else { return }
            detailFailed = true
        }
    }

    private func playRecords(startAt track: Track? = nil) {
        PlayerService.shared.play(tracks: records.map(\.song), source: .none,
                                  startAt: track, context: .recents)
    }

    @MainActor
    private func loadRecords(force: Bool = true) async {
        guard account.provider.supports(.playRanking), account.isLoggedIn, let uid = account.profile?.userId else {
            isLoadingRecords = false
            return
        }
        let requestedWeek = week
        let period = qqRankPeriod
        let binding = MusicProviderContext.shared.authenticationKey
        let key = "\(binding ?? "guest"):\(uid):\(week):\(period)"
        guard let ticket = recordsRefresh.begin(key: "\(key):\(SidebarResources.playbackRevision):\(statisticsRevision)", lifetime: 300, force: force) else { return }
        if displayedRecordsKey != key { records = []; displayedRecordsKey = key }
        recordError = nil
        isLoadingRecords = records.isEmpty
        var success = false
        defer {
            if recordsRefresh.isCurrent(ticket) { isLoadingRecords = false }
            recordsRefresh.finish(ticket, success: success)
        }
        do {
            let fetched = try await (account.provider == .qq ? PlatformMusicAPI.shared.qqListeningRank(period: period)
                : NeteaseAPI.playRecords(uid: uid, week: requestedWeek))
            guard recordsRefresh.accepts(ticket), MusicProviderContext.shared.authenticationKey == binding, week == requestedWeek, qqRankPeriod == period else { return }
            records = fetched
            success = true
            isLoadingRecords = false
        } catch {
            guard recordsRefresh.accepts(ticket), MusicProviderContext.shared.authenticationKey == binding, week == requestedWeek, qqRankPeriod == period else { return }
            recordError = "听歌排行加载失败，请重试"
            isLoadingRecords = false
        }
    }
}
