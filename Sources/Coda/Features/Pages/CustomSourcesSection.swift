import SwiftUI
import UniformTypeIdentifiers

/// Pickers and alerts for the custom-source section, hosted on the settings
/// Form (iOS dismisses presentations hosted on a Section when the List re-renders).
@MainActor
final class CustomSourcesPresentation: ObservableObject {
    @Published var showsFileImporter = false
    @Published var showsLinkPrompt = false
    @Published var link = ""
    @Published var isImporting = false
    @Published var importError: String?
    @Published var pendingDeletion: CustomSource?

    func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            run { try await CustomSourceStore.shared.importScript(data, fileName: url.lastPathComponent) }
        } catch {
            importError = error.localizedDescription
        }
    }

    func importLink(_ address: String) {
        run { try await CustomSourceStore.shared.importOnline(address) }
    }

    func exportToClipboard() {
        do {
            Platform.copyToPasteboard(string: try CustomSourceStore.shared.exportData())
            ToastCenter.shared.show(String(localized: "已复制 \(CustomSourceStore.shared.sources.count) 个音源到剪贴板"))
        } catch {
            importError = error.localizedDescription
        }
    }

    func importFromClipboard() {
        guard !isImporting else { return }
        guard let text = Platform.pasteboardString, !text.isEmpty else {
            importError = String(localized: "剪贴板里没有音源")
            return
        }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let count = try await CustomSourceStore.shared.importData(text)
                ToastCenter.shared.show(String(localized: "已从剪贴板导入 \(count) 个音源"))
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> CustomSource) {
        guard !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let source = try await operation()
                if case .failed(let message) = CustomSourceStore.shared.statuses[source.id] {
                    importError = String(localized: "已导入「\(source.name)」，但加载失败：\(message)")
                } else {
                    ToastCenter.shared.show(String(localized: "已导入「\(source.name)」"))
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// Settings → 自定义音源: scripts the user imports in the LX Music custom-source
/// format. Coda ships none; enabled scripts are tried, top to bottom, before
/// the platform accounts when a track cannot play on its own platform.
struct CustomSourcesSection: View {
    @ObservedObject private var store = CustomSourceStore.shared
    @ObservedObject var presentation: CustomSourcesPresentation
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    /// The settings Form's edit mode (a @State binding in SettingsView): while
    /// active, List shows its native reorder grips, as in the play queue.
    @Environment(\.editMode) private var editMode
    private var isReordering: Bool { editMode?.wrappedValue.isEditing == true }
    private func setReordering(_ on: Bool) {
        withAnimation { editMode?.wrappedValue = on ? .active : .inactive }
    }
    #else
    private let isReordering = false
    #endif
    @State private var dragging: String?
    /// Where the current drag began: the row's index and height.
    @State private var dragStart: (index: Int, height: CGFloat)?
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        Section {
            ForEach(store.sources) { source in
                row(source)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: SourceRowFrames.self,
                                                   value: [source.id: proxy.frame(in: .global)])
                        }
                    }
            }
            #if os(iOS)
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            #endif
            .onDelete { offsets in
                offsets.map { store.sources[$0] }.forEach { store.remove($0.id) }
            }

            Button { presentation.showsFileImporter = true } label: {
                actionLabel("从文件导入", systemImage: "doc.badge.plus")
            }
            .modifier(AccountActionStyle())
            Button {
                presentation.link = ""
                presentation.showsLinkPrompt = true
            } label: {
                actionLabel("从链接导入", systemImage: "link.badge.plus")
            }
            .modifier(AccountActionStyle())
            Button { presentation.exportToClipboard() } label: {
                actionLabel("导出音源到剪贴板", systemImage: "square.and.arrow.up")
            }
            .modifier(AccountActionStyle())
            .disabled(store.sources.isEmpty)
            Button { presentation.importFromClipboard() } label: {
                actionLabel("从剪贴板导入音源", systemImage: "square.and.arrow.down")
            }
            .modifier(AccountActionStyle())
            if presentation.isImporting { ProgressView("正在导入音源…") }
        } header: {
            HStack {
                Text("自定义音源")
                #if os(iOS)
                Spacer()
                if store.sources.count > 1 || isReordering {
                    Button(isReordering ? "完成" : "排序") { setReordering(!isReordering) }
                    .font(Theme.Typography.caption.weight(.semibold))
                    .textCase(nil)
                }
                #endif
            }
        } footer: {
            Text("Coda 不提供、也不推荐任何音源，导入的脚本及其访问的服务由你自行选择并承担责任，请遵守所在地法律法规。")
        }
        .disabled(presentation.isImporting)
        .onPreferenceChange(SourceRowFrames.self) { rowFrames = $0 }
        .task { await store.loadEnabled() }
        #if os(iOS)
        .onChange(of: store.sources.count) { count in
            if count < 2 { setReordering(false) }
        }
        #endif
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func row(_ source: CustomSource) -> some View {
        HStack(spacing: Theme.Spacing.control) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { source.isEnabled }, set: { store.setEnabled(source.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            availabilityDot(source)
                            Text(source.name)
                        }
                        if let detail = Self.detail(source) {
                            Text(detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        status(source)
                    }
                }
                if let notice = store.updateNotices[source.id] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.log)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                        if let url = notice.url {
                            Button("查看更新") { openURL(url) }
                                .font(Theme.Typography.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            #if os(macOS)
            if store.sources.count > 1 {
                dragHandle(source)
            }
            #endif
        }
        .contextMenu(isReordering ? nil : ContextMenu {
            Button {
                Task { await store.reload(source.id) }
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            if let address = source.sourceURL {
                Button {
                    presentation.importLink(address)
                } label: {
                    Label("重新下载", systemImage: "arrow.down.circle")
                }
            }
            if let index = store.sources.firstIndex(of: source) {
                if index > 0 {
                    Button {
                        store.move(fromOffsets: [index], toOffset: index - 1)
                    } label: {
                        Label("上移", systemImage: "arrow.up")
                    }
                }
                if index < store.sources.count - 1 {
                    Button {
                        store.move(fromOffsets: [index], toOffset: index + 2)
                    } label: {
                        Label("下移", systemImage: "arrow.down")
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                presentation.pendingDeletion = source
            } label: {
                Label("删除", systemImage: "trash")
            }
        })
    }

    #if os(macOS)
    /// The ≡ grip, like the play queue's: drag it up or down and the row
    /// trades places with each row the pointer passes.
    private func dragHandle(_ source: CustomSource) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(dragging == source.id ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            .frame(width: 28, height: 36)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            #endif
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in reorder(source.id, by: value.translation.height) }
                    .onEnded { _ in
                        dragging = nil
                        dragStart = nil
                    }
            )
            .accessibilityLabel("拖动以调整「\(source.name)」的顺序")
    }

    /// Moves the row one place per row height dragged, counted from where
    /// the drag began, so it does not depend on other rows' frames updating.
    private func reorder(_ id: String, by translation: CGFloat) {
        guard let current = store.sources.firstIndex(where: { $0.id == id }) else { return }
        if dragging != id || dragStart == nil {
            dragging = id
            dragStart = (current, max(rowFrames[id]?.height ?? 60, 30))
        }
        guard let start = dragStart else { return }
        let target = min(max(start.index + Int((translation / start.height).rounded()), 0), store.sources.count - 1)
        guard target != current else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.move(fromOffsets: [current], toOffset: target > current ? target + 1 : target)
        }
    }
    #endif

    /// Green when the script loaded and declared platforms, red when it failed,
    /// gray (breathing while loading) when it is off or not loaded yet.
    private func availabilityDot(_ source: CustomSource) -> some View {
        let status = store.statuses[source.id] ?? .idle
        let (color, label): (Color, String) = {
            guard source.isEnabled else { return (.gray, String(localized: "已停用")) }
            switch status {
            case .ready: return (.green, String(localized: "可用"))
            case .failed: return (.red, String(localized: "不可用"))
            case .loading: return (.gray, String(localized: "加载中…"))
            case .idle: return (.gray, String(localized: "未加载"))
            }
        }()
        return StatusDot(color: color, isChecking: source.isEnabled && status == .loading, help: label,
                         accessibilityLabel: String(localized: "音源状态：\(label)"))
    }

    @ViewBuilder
    private func status(_ source: CustomSource) -> some View {
        switch store.statuses[source.id] ?? .idle {
        case .loading:
            Text("正在加载…")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        case .idle, .ready:
            if let summary = Self.capabilitySummary(source.capabilities) {
                Text(summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "v1.2 · 作者"; versions already spelled with a leading v keep it once.
    static func detail(_ source: CustomSource) -> String? {
        let version = source.version.trimmingCharacters(in: .whitespaces)
        let versionText = version.isEmpty ? nil
            : (version.first.map { $0 == "v" || $0 == "V" } == true ? version : "v\(version)")
        let parts = [versionText, source.author.isEmpty ? nil : source.author].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let platformNames = ["wy": "网易云", "tx": "QQ 音乐", "kg": "酷狗", "kw": "酷我", "mg": "咪咕"]

    /// "网易云、QQ 音乐 · 最高 flac".
    static func capabilitySummary(_ capabilities: [String: [String]]?) -> String? {
        guard let capabilities, !capabilities.isEmpty else { return nil }
        let order = ["wy", "tx", "kg", "kw", "mg"]
        let names = order.filter { capabilities[$0] != nil }.compactMap { platformNames[$0] }
        let best = CustomUnblockSource.tokenOrder.last { token in capabilities.values.contains { $0.contains(token) } }
        return names.joined(separator: "、") + (best.map { " · 最高 \($0)" } ?? "")
    }
}

private struct SourceRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CustomSourcesPresenter: ViewModifier {
    @ObservedObject var presentation: CustomSourcesPresentation

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $presentation.showsFileImporter,
                          allowedContentTypes: [.javaScript, .plainText, .text, .data]) { result in
                switch result {
                case .success(let url):
                    presentation.importFile(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { presentation.importError = error.localizedDescription }
                }
            }
            .alert("从链接导入", isPresented: $presentation.showsLinkPrompt) {
                TextField("https://", text: $presentation.link)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("导入") { presentation.importLink(presentation.link) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("输入音源脚本的下载地址")
            }
            .alert("导入失败", isPresented: Binding(get: { presentation.importError != nil },
                                                set: { if !$0 { presentation.importError = nil } })) {
                Button("好", role: .cancel) { presentation.importError = nil }
            } message: {
                Text(presentation.importError ?? "")
            }
            .alert("删除音源？", isPresented: Binding(get: { presentation.pendingDeletion != nil },
                                                 set: { if !$0 { presentation.pendingDeletion = nil } }),
                   presenting: presentation.pendingDeletion) { source in
                Button("删除", role: .destructive) { CustomSourceStore.shared.remove(source.id) }
                Button("取消", role: .cancel) {}
            } message: { source in
                Text("将删除「\(source.name)」，之后需要重新导入才能使用。")
            }
    }
}
