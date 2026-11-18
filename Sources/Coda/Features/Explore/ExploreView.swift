import SwiftUI

private struct ExploreCategoryChip: Identifiable, Equatable {
    let id: String
    let title: String
    var qqCategoryID: Int? = nil
}

@MainActor
final class ExploreViewModel: ObservableObject {
    /// Shared so category selection and loaded pages survive sidebar switches.
    static let shared = ExploreViewModel()

    static let categories: [String] = [
        "全部", "推荐歌单", "精品歌单", "排行榜", "官方",
        "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
        "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
        "学习", "工作", "运动", "驾车", "夜晚",
    ]

    @Published var selectedCategory = "全部"
    @Published var playlists: [PlaylistSummary] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published private var qqCategories: [ExploreCategoryChip] = []
    @Published private(set) var qqCategoriesFailed = false
    private let qqCategoryRefresh = PanelRefreshGate()
    private var offset = 0
    private var highQualityBefore = 0
    private var exposureIDs: [UInt64] = []
    private var loadTask: Task<Void, Never>?

    @Published var errorMessage: String?
    private struct Snapshot {
        var playlists: [PlaylistSummary]
        var toplists: [ToplistItem]
        var offset: Int
        var before: Int
        var exposureIDs: [UInt64]
        var hasMore: Bool
        var fetchedAt: Date
    }
    private var snapshots: [String: Snapshot] = [:]
    private var requestID = UUID()
    private var authentication: String?

    fileprivate func categoryChips(for provider: MusicProvider) -> [ExploreCategoryChip] {
        let builtIn = provider.exploreCategories.map { ExploreCategoryChip(id: $0, title: $0) }
        return provider == .qq ? builtIn + qqCategories : builtIn
    }

    func refreshQQCategories(force: Bool = false) async {
        guard MusicProviderContext.shared.current == .qq,
              let request = qqCategoryRefresh.begin(key: "qq", lifetime: 900, force: force) else { return }
        var success = false
        defer { qqCategoryRefresh.finish(request, success: success) }
        do {
            let categories = try await QQMusicAPI.shared.playlistCategories()
            guard qqCategoryRefresh.accepts(request), MusicProviderContext.shared.current == .qq else { return }
            qqCategories = categories.map {
                ExploreCategoryChip(id: "qq-category-\($0.id)", title: $0.name, qqCategoryID: $0.id)
            }
            if selectedCategory.hasPrefix("qq-category-"), !qqCategories.contains(where: { $0.id == selectedCategory }) {
                select("全部")
            }
            success = true
            qqCategoriesFailed = false
        } catch {
            guard qqCategoryRefresh.accepts(request), MusicProviderContext.shared.current == .qq else { return }
            qqCategoriesFailed = qqCategories.isEmpty
        }
    }

    func select(_ category: String) {
        guard category != selectedCategory else { return }
        loadTask?.cancel()
        requestID = UUID()
        isLoading = false
        selectedCategory = category
        restore(category)
        loadTask = Task { await refresh() }
    }

    private func restore(_ category: String) {
        let saved = snapshots[category]
        playlists = saved?.playlists ?? []
        toplists = saved?.toplists ?? []
        offset = saved?.offset ?? 0
        highQualityBefore = saved?.before ?? 0
        exposureIDs = saved?.exposureIDs ?? []
        hasMore = saved?.hasMore ?? true
        errorMessage = nil
    }

    func refresh(force: Bool = false) async {
        let binding = MusicProviderContext.shared.authenticationKey
        if binding != authentication {
            authentication = binding
            snapshots = [:]
            requestID = UUID(); isLoading = false
            restore(selectedCategory)
        }
        // 各平台分类不同（酷狗没有“全部”），当前分类不存在时回到该平台的第一个分类。
        let chips = categoryChips(for: MusicProviderContext.shared.current)
        if !chips.contains(where: { $0.id == selectedCategory }) {
            selectedCategory = chips.first?.id ?? "全部"
            restore(selectedCategory)
        }
        if !force, let saved = snapshots[selectedCategory], Date().timeIntervalSince(saved.fetchedAt) < 900 { return }
        await loadMore(reset: true)
    }

    func loadMore(reset: Bool = false) async {
        guard reset || (!isLoading && hasMore) else { return }
        let request = UUID()
        requestID = request
        let category = selectedCategory
        let binding = MusicProviderContext.shared.authenticationKey
        let provider = MusicProviderContext.shared.current
        let qqCategoryID = provider == .qq ? qqCategories.first { $0.id == category }?.qqCategoryID : nil
        let kugouSort = provider == .kugou ? KugouMusicAPI.PlaylistSort.allCases.first { $0.title == category } : nil
        let requestedOffset = reset ? 0 : offset
        let requestedBefore = reset ? 0 : highQualityBefore
        let requestedExposure = reset ? [] : exposureIDs
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            var fresh: [PlaylistSummary] = []
            var charts: [ToplistItem] = []
            var more = false
            var before = 0
            var nextExposure = requestedExposure
            switch (provider, category, qqCategoryID) {
            case (.qq, _, let id?):
                let page = try await PlatformMusicAPI.shared.qqCategoryPlaylists(id: id, page: requestedOffset)
                fresh = page.items
                more = page.more
            case (.qishui, "全部", _), (.qishui, "推荐歌单", _):
                let page = try await PlatformMusicAPI.shared.qishuiFeaturedPlaylists(excluding: requestedExposure)
                fresh = page.playlists
                var seen = Set(requestedExposure)
                nextExposure += page.exposureIDs.filter { seen.insert($0).inserted }
                more = page.hasMore && nextExposure.count > requestedExposure.count
            case (.kugou, _, _) where kugouSort != nil:
                // 酷狗分类每次固定返回 40 个，没有下一页。
                fresh = try await PlatformMusicAPI.shared.kugouSortedPlaylists(kugouSort!)
            case (_, "排行榜", _): charts = try await NeteaseAPI.toplists()
            case (_, "推荐歌单", _): fresh = try await NeteaseAPI.personalizedPlaylists(limit: 100)
            case (_, "精品歌单", _):
                let result = try await NeteaseAPI.highQualityPlaylists(before: requestedBefore)
                fresh = result.playlists; before = result.lasttime ?? 0; more = result.more ?? false
            default:
                let result = try await NeteaseAPI.topPlaylists(category: category, offset: requestedOffset)
                fresh = result.playlists; more = (result.more ?? false) && requestedOffset + 50 < 500
            }
            guard !Task.isCancelled, requestID == request, selectedCategory == category,
                  binding == MusicProviderContext.shared.authenticationKey else { return }
            let existing = reset ? Set<Int>() : Set(playlists.map(\.id))
            let additions = fresh.filter { !existing.contains($0.id) }
            playlists = (reset ? [] : playlists) + additions
            toplists = charts
            offset = requestedOffset + (qqCategoryID == nil ? 50 : 1); highQualityBefore = before
            exposureIDs = nextExposure
            hasMore = more && ((provider != .qishui && qqCategoryID == nil) || !additions.isEmpty)
            errorMessage = nil
            snapshots[category] = Snapshot(playlists: playlists, toplists: toplists, offset: offset,
                                           before: before, exposureIDs: exposureIDs, hasMore: hasMore,
                                           fetchedAt: reset ? Date() : snapshots[category]?.fetchedAt ?? Date())
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct ExploreView: View {
    private var phoneLayout = PhonePageLayout()
    #if os(iOS)
    @Environment(\.iPadChrome) private var iPadChrome
    @ScaledMetric(relativeTo: .subheadline) private var categoryHeight: CGFloat = 44
    #endif
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var player: PlayerService

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScenePreservingScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.section) {
                categoryChips
                    .pageHeaderTopPadding(8)
                    .accessibilityIdentifier("exploreCategories")

                if account.provider == .qq, model.qqCategoriesFailed {
                    Button("重试加载分类") { Task { await model.refreshQQCategories(force: true) } }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, phoneLayout.contentInset)
                }

                if let error = model.errorMessage {
                    ErrorStateView(message: error) { Task { await model.refresh(force: true) } }
                }
                if model.selectedCategory == "排行榜" {
                    ToplistGrid(toplists: model.toplists)
                        .padding(.horizontal, phoneLayout.contentInset)
                } else {
                    CardGrid {
                        ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                            NavigationLink(value: Destination.playlist(playlist.id)) {
                                PlaylistCoverCard(playlist: playlist) {
                                    playPlaylist(playlist.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .staggeredAppearance(index: index % 10, id: "explore-\(playlist.id)")
                        }
                    }
                    .padding(.horizontal, phoneLayout.contentInset)

                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, Theme.Spacing.phonePage)
                    } else if model.hasMore && model.errorMessage == nil {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadMore() }
                            }
                    } else if model.errorMessage == nil, model.playlists.isEmpty,
                              categories.contains(where: { $0.id == model.selectedCategory && $0.qqCategoryID != nil }) {
                        EmptyStateView(icon: "music.note.list", title: "暂无歌单")
                            .padding(.vertical, Theme.Spacing.section)
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .appRootNavigationTitle(String(localized: "精选"))
        .panelRefresh(key: "explore") { force in
            async let categories: Void = model.refreshQQCategories(force: force)
            await model.refresh(force: force)
            await categories
        }
    }

    private var categories: [ExploreCategoryChip] { model.categoryChips(for: account.provider) }

    @ViewBuilder
    private var categoryChips: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad, iPadChrome == .legacy {
            LegacyIPadExploreCategories(categories: categories,
                selectedCategory: model.selectedCategory, inset: phoneLayout.contentInset,
                onSelect: model.select)
                .frame(height: max(44, categoryHeight) + Theme.Spacing.micro * 2)
        } else {
            swiftUICategoryChips
        }
        #else
        swiftUICategoryChips
        #endif
    }

    private var swiftUICategoryChips: some View {
        ScenePreservingScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                Spacer().frame(width: phoneLayout.contentInset - 8)
                ForEach(categories) { category in
                    Button {
                        model.select(category.id)
                    } label: {
                        if category.qqCategoryID == nil {
                            Text(LocalizedStringKey(category.title))
                        } else {
                            Text(verbatim: category.title)
                        }
                    }
                    .buttonStyle(.chip(isSelected: model.selectedCategory == category.id))
                    .accessibilityIdentifier("explore.category.\(category.id)")
                    .accessibilityAddTraits(model.selectedCategory == category.id ? .isSelected : [])
                }
                Spacer().frame(width: phoneLayout.contentInset - 8)
            }
            .padding(.vertical, Theme.Spacing.micro)
        }
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await NeteaseAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Toplist grid

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: Theme.Spacing.group)],
            alignment: .leading, spacing: Theme.Spacing.section
        ) {
            ForEach(toplists) { toplist in
                NavigationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: Theme.Spacing.component) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            Text(toplist.name)
                                .font(Theme.Typography.secondary.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.control)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []

    var body: some View {
        ScenePreservingScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            if toplists.isEmpty {
                toplists = (try? await NeteaseAPI.toplists()) ?? []
            }
        }
    }
}


extension MusicProvider {
    var exploreCategories: [String] {
        switch self {
        case .netease: return ExploreViewModel.categories
        case .qishui: return ["全部", "推荐歌单"]
        case .kugou: return KugouMusicAPI.PlaylistSort.allCases.map(\.title) + ["排行榜"]
        default: return ["全部", "推荐歌单", "排行榜"]
        }
    }
}

#if os(iOS)
/// On iPadOS 16 the nested SwiftUI scroll host can hit the chip's drawing view
/// without delivering its Button action. Native controls own the touch sequence
/// here, including cancellation when a tap turns into a horizontal drag.
private struct LegacyIPadExploreCategories: UIViewRepresentable {
    let categories: [ExploreCategoryChip]
    let selectedCategory: String
    let inset: CGFloat
    let onSelect: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> CategoryScrollView { CategoryScrollView() }
    func updateUIView(_ view: CategoryScrollView, context: Context) {
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        view.update(categories: categories, selected: selectedCategory, inset: inset, onSelect: onSelect)
    }

    final class CategoryScrollView: UIScrollView {
        private let stack = UIStackView()
        private var categories: [ExploreCategoryChip] = []
        private var onSelect: (String) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            showsHorizontalScrollIndicator = false
            delaysContentTouches = false
            alwaysBounceHorizontal = true
            stack.axis = .horizontal
            stack.spacing = Theme.Spacing.small
            stack.alignment = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func touchesShouldCancel(in view: UIView) -> Bool {
            view is UIControl || super.touchesShouldCancel(in: view)
        }

        func update(categories: [ExploreCategoryChip], selected: String, inset: CGFloat,
                    onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: Theme.Spacing.micro, leading: inset, bottom: Theme.Spacing.micro, trailing: inset)
            if self.categories != categories {
                self.categories = categories
                for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
                for (index, category) in categories.enumerated() {
                    let button = UIButton(type: .system)
                    button.tag = index
                    button.setContentHuggingPriority(.required, for: .horizontal)
                    button.setContentCompressionResistancePriority(.required, for: .horizontal)
                    button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
                    stack.addArrangedSubview(button)
                }
            }
            for (index, child) in stack.arrangedSubviews.enumerated() {
                guard let button = child as? UIButton else { continue }
                let category = categories[index]
                let isSelected = category.id == selected
                var configuration = UIButton.Configuration.filled()
                configuration.title = category.qqCategoryID == nil
                    ? NSLocalizedString(category.title, comment: "Explore category") : category.title
                configuration.cornerStyle = .capsule
                configuration.baseForegroundColor = isSelected ? .white : .label
                configuration.baseBackgroundColor = isSelected ? UIColor(Theme.accent) : UIColor.label.withAlphaComponent(0.06)
                configuration.contentInsets = NSDirectionalEdgeInsets(
                    top: Theme.Spacing.small, leading: Theme.Spacing.control,
                    bottom: Theme.Spacing.small, trailing: Theme.Spacing.control)
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    let font = UIFont.preferredFont(forTextStyle: .subheadline)
                    attributes.font = UIFont.systemFont(ofSize: font.pointSize, weight: isSelected ? .semibold : .medium)
                    return attributes
                }
                button.isSelected = isSelected
                button.configuration = configuration
                button.isAccessibilityElement = true
                button.accessibilityIdentifier = "explore.category.\(category.id)"
                button.accessibilityLabel = configuration.title
                button.accessibilityValue = isSelected ? "已选择" : "未选择"
                button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
            }
        }

        @objc private func selectCategory(_ button: UIButton) {
            guard categories.indices.contains(button.tag) else { return }
            onSelect(categories[button.tag].id)
        }
    }
}
#endif
