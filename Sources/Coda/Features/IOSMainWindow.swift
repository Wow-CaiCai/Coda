import SwiftUI

#if os(iOS)
enum IPadChrome {
    case native
    case legacy
}

private struct IPadChromeKey: EnvironmentKey {
    static let defaultValue: IPadChrome = .legacy
}

private struct LegacyIPadSystemInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

private struct LegacyIPadKeyboardOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct NowPlayingTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var legacyIPadKeyboardOverlap: CGFloat {
        get { self[LegacyIPadKeyboardOverlapKey.self] }
        set { self[LegacyIPadKeyboardOverlapKey.self] = newValue }
    }

    var legacyIPadSystemInsets: EdgeInsets {
        get { self[LegacyIPadSystemInsetsKey.self] }
        set { self[LegacyIPadSystemInsetsKey.self] = newValue }
    }

    var nowPlayingTransitionNamespace: Namespace.ID? {
        get { self[NowPlayingTransitionNamespaceKey.self] }
        set { self[NowPlayingTransitionNamespaceKey.self] = newValue }
    }

    var iPadChrome: IPadChrome {
        get { self[IPadChromeKey.self] }
        set { self[IPadChromeKey.self] = newValue }
    }
}

@available(iOS 26.0, *)
private struct NativeIPadRoot: View {
    @Binding var path: [Destination]

    var body: some View {
        MainWindow(path: $path)
            .environment(\.iPadChrome, .native)
    }
}

private struct LegacyIPadRoot: View {
    @Binding var path: [Destination]
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastActiveSystemInsets: EdgeInsets?
    @State private var keyboardOcclusion: CGFloat = 0

    var body: some View {
        // Keep one full-window canvas. Keyboard avoidance is applied once,
        // explicitly, to destinations and chrome rather than to this root.
        GeometryReader { viewport in
            let isCompact = viewport.size.width < WindowLayout.compactWidth
            let insets = scenePhase == .active ? viewport.safeAreaInsets
                : (lastActiveSystemInsets ?? viewport.safeAreaInsets)
            MainWindow(path: $path)
                .environment(\.iPadChrome, .legacy)
                .environment(\.legacyIPadSystemInsets, insets)
                .environment(\.legacyIPadKeyboardOverlap,
                             max(0, keyboardOcclusion - insets.bottom))
                .ignoresSafeArea(.container, edges: isCompact ? [] : .vertical)
                .onAppear {
                    if scenePhase == .active { lastActiveSystemInsets = viewport.safeAreaInsets }
                }
                .onChange(of: viewport.safeAreaInsets) { next in
                    if scenePhase == .active { lastActiveSystemInsets = next }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { lastActiveSystemInsets = viewport.safeAreaInsets }
                }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(LegacyIPadKeyboardObserver(occlusion: $keyboardOcclusion))
    }
}

@MainActor
private protocol LegacyKeyboardSafeAreaHosting {
    func configureLegacySafeArea(ownsContainerInsets: Bool, preservesContainerInsets: Bool)
}

extension UIHostingController: LegacyKeyboardSafeAreaHosting {
    fileprivate func configureLegacySafeArea(ownsContainerInsets: Bool, preservesContainerInsets: Bool) {
        if #available(iOS 16.4, *) {
            let excluded: SafeAreaRegions = ownsContainerInsets ? .all : .keyboard
            // The wide canvas owns its insets. Compact navigation restores
            // container regions so UIKit can reserve the real bar and indicators.
            let next = preservesContainerInsets
                ? safeAreaRegions.union(.container).subtracting(.keyboard)
                : safeAreaRegions.subtracting(excluded)
            if safeAreaRegions != next { safeAreaRegions = next }
        }
    }
}

@MainActor
private func configureLegacyHostingSafeAreas(_ controller: UIViewController,
                                            insideNavigation: Bool = false,
                                            preservesContainerInsets: Bool? = nil) {
    let preservesContainerInsets = preservesContainerInsets
        ?? ((controller.viewIfLoaded?.window?.bounds.width ?? .infinity) < WindowLayout.compactWidth)
    let ownsContainerInsets = insideNavigation || controller is UINavigationController
    (controller as? LegacyKeyboardSafeAreaHosting)?
        .configureLegacySafeArea(ownsContainerInsets: ownsContainerInsets,
                                  preservesContainerInsets: preservesContainerInsets)
    for child in controller.children {
        configureLegacyHostingSafeAreas(child, insideNavigation: ownsContainerInsets,
                                        preservesContainerInsets: preservesContainerInsets)
    }
}

/// A pushed destination can get a new hosting controller without resizing the
/// window. Configure that controller before it accepts text input as well.
struct LegacyIPadHostingSafeAreaProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.scheduleConfiguration() }

    final class Probe: UIView {
        private var pending = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleConfiguration()
        }
        func scheduleConfiguration() {
            guard window != nil, !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                if let root = self.window?.rootViewController { configureLegacyHostingSafeAreas(root) }
            }
        }
    }
}

/// Observe the keyboard in this window's coordinates, independently of
/// SwiftUI's keyboard-safe-area propagation through NavigationStack on iOS 16.
private struct LegacyIPadKeyboardObserver: UIViewRepresentable {
    @Binding var occlusion: CGFloat

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = { height, duration in
            guard occlusion != height else { return }
            withAnimation(.easeOut(duration: duration)) { occlusion = height }
        }
    }

    static func dismantleUIView(_ view: Probe, coordinator: Void) {
        view.onChange = nil
    }

    final class Probe: UIView {
        var onChange: ((CGFloat, TimeInterval) -> Void)?
        private var keyboardFrame: CGRect?
        private var updatePending = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                       name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func keyboardChanged(_ notification: Notification) {
            if let root = window?.rootViewController { configureLegacyHostingSafeAreas(root) }
            if notification.name == UIResponder.keyboardWillHideNotification {
                keyboardFrame = nil
            } else {
                keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            }
            publish(duration: notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? TimeInterval ?? 0.25)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                if let root = self.window?.rootViewController {
                    configureLegacyHostingSafeAreas(root)
                }
                self.publish(duration: 0)
            }
        }

        private func publish(duration: TimeInterval) {
            guard let window else { return }
            guard let keyboardFrame else { onChange?(0, duration); return }
            let frame = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let covered = window.bounds.intersection(frame)
            // Floating/split keyboards must not collapse the whole page.
            let docked = !covered.isNull && covered.width >= window.bounds.width * 0.95
                && covered.maxY >= window.bounds.maxY - 1
            onChange?(docked ? covered.height : 0, duration)
        }
    }
}

struct IPadSplitStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationSplitViewStyle(.balanced)
    }
}

/// A native sheet with a window-sized preferred content size. On iPad a form
/// sheet honors that size instead of imposing pageSheet's readable-column width.
/// UIKit still owns its margins, backdrop transform and interactive dismissal.
private struct LegacyPlayerSheet<Content: View, Backdrop: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let content: Content
    let backdrop: Backdrop
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.requestedPresentation = isPresented
        controller.playerContent = AnyView(content.environment(\.self, environment))
        controller.backdropContent = AnyView(backdrop.environment(\.self, environment))
        controller.onDismiss = {
            isPresented = false
            onDismiss()
        }
        controller.synchronize()
    }

    final class Controller: UIViewController, UISheetPresentationControllerDelegate, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
        var requestedPresentation = false
        var playerContent = AnyView(EmptyView())
        var backdropContent = AnyView(EmptyView())
        var onDismiss: (() -> Void)?
        private var hosting: PlayerController?
        private var backgroundHost: UIHostingController<AnyView>?
        private var isDismissing = false

        private var isDraggingPlayer = false

        private var usesUnifiedBackground: Bool { true }

        private var playerRootContent: AnyView {
            if usesUnifiedBackground {
                // One full-screen host owns the artwork and foreground on old iPadOS.
                // A form sheet adds a separate material surface at its top edge.
                let insets = view.window?.safeAreaInsets ?? .zero
                return AnyView(ZStack {
                    backdropContent.ignoresSafeArea()
                    // Read the stationary window, not the moving host.
                    playerContent.padding(EdgeInsets(top: insets.top, leading: insets.left,
                                                     bottom: insets.bottom, trailing: insets.right))
                }
                // Also covers iOS 16.0–16.3, before safeAreaRegions exists.
                .ignoresSafeArea(.container))
            }
            return playerContent
        }


        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updatePreferredSize()
        }

        private func updatePreferredSize() {
            guard let hosting, let size = view.window?.bounds.size,
                  hosting.preferredContentSize != size else { return }
            hosting.preferredContentSize = size
        }

        func synchronize() {
            guard viewIfLoaded?.window != nil, !isDismissing, !isDraggingPlayer else { return }
            if requestedPresentation {
                if let hosting {
                    hosting.rootView = playerRootContent
                    backgroundHost?.rootView = backdropContent
                    updatePreferredSize()
                    return
                }
                let player = PlayerController(rootView: playerRootContent)
                player.modalPresentationStyle = usesUnifiedBackground ? .custom : .formSheet
                if usesUnifiedBackground {
                    if #available(iOS 16.4, *) {
                        // Use the stable window insets supplied above. UIKit's
                        // container insets shrink as the surface moves down,
                        // otherwise SwiftUI enlarges and reflows the player.
                        player.safeAreaRegions.remove(.container)
                    }
                    player.transitioningDelegate = self
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePlayerPan(_:)))
                    pan.delegate = self
                    player.view.addGestureRecognizer(pan)
                }
                player.overrideUserInterfaceStyle = .dark
                player.view.backgroundColor = .clear
                player.preferredContentSize = view.window?.bounds.size ?? view.bounds.size
                if !usesUnifiedBackground, let sheet = player.sheetPresentationController {
                    sheet.detents = [.large()]
                    sheet.prefersGrabberVisible = true
                    sheet.preferredCornerRadius = 0
                    sheet.prefersEdgeAttachedInCompactHeight = true
                    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
                    if #available(iOS 17.0, *) { sheet.prefersPageSizing = false }
                    sheet.delegate = self
                }
                hosting = player
                if !usesUnifiedBackground {
                    let background = UIHostingController(rootView: backdropContent)
                    background.view.backgroundColor = .black
                    background.view.isUserInteractionEnabled = false
                    background.view.accessibilityElementsHidden = true
                    background.view.alpha = 0
                    // This view belongs to UIKit's presentation container, not
                    // player.view. Keep its hosting controller independent: making
                    // it a child of player violates UIKit's containment checks.
                    backgroundHost = background
                    player.onContainerLayout = { [weak self] in self?.placeBackground() }
                    player.onVisibilityChange = { [weak self] visible, coordinator in
                        self?.placeBackground()
                        guard let backdrop = self?.backgroundHost?.view else { return }
                        if let coordinator {
                            coordinator.animate(alongsideTransition: { _ in
                                backdrop.alpha = visible ? 1 : 0
                            })
                        } else {
                            backdrop.alpha = visible ? 1 : 0
                        }
                    }
                }
                present(player, animated: true)

            } else if let hosting {
                isDismissing = true
                hosting.dismiss(animated: true) { [weak self] in
                    self?.finishDismissal()
                }
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !isDismissing, !isDraggingPlayer, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let player = hosting, !player.isBeingPresented else { return false }
            let bounds = player.view.bounds
            let insets = player.view.safeAreaInsets
            let safeHeight = bounds.height - insets.top - insets.bottom
            let handleInset = UIDevice.current.userInterfaceIdiom == .pad
                ? NowPlayingSplitGeometry.verticalInset(height: safeHeight) : NowPlayingPresentationMetrics.indicatorTopSpacing
            let handleBottom = insets.top + handleInset + 44
            return pan.location(in: player.view).y <= handleBottom && pan.velocity(in: player.view).y > 0
        }

        @objc private func handlePlayerPan(_ pan: UIPanGestureRecognizer) {
            guard let player = hosting,
                  let presentation = player.presentationController as? LegacyPlayerPresentationController else { return }
            // Drag only the surfaces until release. Starting UIKit dismissal here
            // makes even an abandoned drag run a controller disappearance cycle.
            let coordinateView = player.view.window ?? player.view
            let translation = max(0, pan.translation(in: coordinateView).y)
            switch pan.state {
            case .began:
                guard !isDismissing, !isDraggingPlayer else { return }
                isDraggingPlayer = true
                presentation.updatePlayerDrag(translation: translation)
            case .changed:
                guard isDraggingPlayer else { return }
                presentation.updatePlayerDrag(translation: translation)
            case .ended:
                guard isDraggingPlayer else { return }
                let predicted = translation + pan.velocity(in: coordinateView).y * 0.18
                if NowPlayingPresentationMetrics.shouldDismiss(translation: translation, predictedTranslation: predicted) {
                    isDraggingPlayer = false
                    isDismissing = true
                    // The dismissal animator continues from the current drag
                    // position. UIKit is involved only once closing is committed.
                    player.dismiss(animated: true)
                } else {
                    restorePlayerAfterDrag(presentation)
                }
            case .cancelled, .failed:
                guard isDraggingPlayer else { return }
                restorePlayerAfterDrag(presentation)
            default: break
            }
        }

        private func restorePlayerAfterDrag(_ presentation: LegacyPlayerPresentationController) {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.25,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                presentation.updatePlayerDrag(translation: 0)
            } completion: { [weak self] _ in
                guard let self else { return }
                self.isDraggingPlayer = false
                self.synchronize()
            }
        }

        func presentationController(forPresented presented: UIViewController,
                                    presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            guard usesUnifiedBackground else { return nil }
            let controller = LegacyPlayerPresentationController(presentedViewController: presented,
                                                                  presenting: presenting)
            controller.onDismissalEnd = { [weak self] completed in
                guard let self else { return }
                if completed { self.finishDismissal() }
                else {
                    self.isDismissing = false
                    // Apply any request deferred during the transition.
                    DispatchQueue.main.async { [weak self] in self?.synchronize() }
                }
            }
            return controller
        }

        func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                                 source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            usesUnifiedBackground ? LegacyPlayerTransition(presenting: true) : nil
        }

        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            usesUnifiedBackground ? LegacyPlayerTransition(presenting: false) : nil
        }

        // Put the single artwork renderer above the dimmed browser and below
        // the sheet. Its bounds are the entire presentation container, including
        // status-bar and iPad margins; the controls keep native sheet safe areas.
        private func placeBackground() {
            guard let hosting, let background = backgroundHost?.view,
                  let container = hosting.presentationController?.containerView else { return }
            var surface = hosting.view!
            while let parent = surface.superview, parent !== container {
                surface = parent
            }
            guard surface.superview === container else { return }
            if background.superview !== container {
                container.insertSubview(background, belowSubview: surface)
            }
            background.frame = container.bounds
            background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        final class PlayerController: UIHostingController<AnyView> {
            var onContainerLayout: (() -> Void)?
            var onVisibilityChange: ((Bool, UIViewControllerTransitionCoordinator?) -> Void)?

            override func viewWillAppear(_ animated: Bool) {
                super.viewWillAppear(animated)
                onVisibilityChange?(true, transitionCoordinator)
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                onContainerLayout?()
            }

            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                if isBeingDismissed { onVisibilityChange?(false, transitionCoordinator) }
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal()
        }

        private func finishDismissal() {
            guard hosting != nil else { return }
            backgroundHost?.view.removeFromSuperview()
            backgroundHost = nil
            hosting = nil
            isDraggingPlayer = false
            requestedPresentation = false
            isDismissing = false
            onDismiss?()
        }
    }
}

public struct IOSMainWindow: View {
    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared
    @StateObject private var updater = IOSUpdater.shared
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @State private var pendingPlayerDestination: (() -> Void)?
    @State private var legacyPlayerBackgroundActive = false
    @Namespace private var nowPlayingTransition
    @Environment(\.colorScheme) private var systemColorScheme

    /// The app's intended scheme, read on this ancestor so the search-active
    /// tab environment can't invert it (#31).
    private var resolvedColorScheme: ColorScheme {
        settings.appearance.colorScheme ?? systemColorScheme
    }

    @State private var selectedTab: IOSTab = .home
    @State private var legacyBarCollapsed = false
    @State private var lastLegacyMainTab: IOSTab = .home
    @State private var legacyKeyboardVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showLogin = false
    @State private var homePath: [Destination] = []
    @State private var explorePath: [Destination] = []
    @State private var searchPath: [Destination] = []
    @State private var libraryPath: [Destination] = []
    @State private var iPadPath: [Destination] = []

    public init() {}

    public var body: some View {
        presentationRoot
            .environment(\.nowPlayingTransitionNamespace, nowPlayingTransition)
            .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }, enabled: !player.showNowPlaying))
            .modifier(MeteredDownloadAlert(enabled: !player.showNowPlaying))
            .environmentObject(player)
            .environmentObject(account)
        .onChange(of: account.sessionRevision) { _ in
            homePath = []; explorePath = []; searchPath = []; libraryPath = []; iPadPath = []
        }
            .environmentObject(settings)
            .environmentObject(toasts)
            .environmentObject(artworkStore)
            .tint(Theme.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.openLogin, { showLogin = true })
            .environment(\.openDestination, openDestination)
            .modifier(PlaybackLifecycle())
            .task {
                // Prepare independently of authentication/download setup and page transitions.
                _ = await ArtworkFlowRenderer.prepared()
            }
            .task {
                await DownloadManager.shared.start()
                await account.bootstrap()
                if settings.autoCheckUpdates {
                    IOSUpdater.shared.check(interactive: false)
                }
            }
            .onChange(of: player.showNowPlaying) { presented in
                if #unavailable(iOS 18.0), presented { legacyPlayerBackgroundActive = true }
            }
            .task(id: needsSharedArtwork) {
                artworkStore.setArtworkNeeded(needsSharedArtwork)
            }
            .sheet(isPresented: $updater.showSheet) {
                IOSUpdaterSheet()
            }
            .sheet(isPresented: $showLogin) {
                LoginSheet()
                    .environmentObject(account)
                    .environmentObject(toasts)
            }
            .modifier(FirstLaunchOnboarding())
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let toast = toasts.current {
                        ToastView(toast: toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !player.hasCurrentTrack {
                        PlaybackHandoffBanner()
                    }
                }
                .padding(.top, 8)
            }
            .animation(.spring(duration: 0.3), value: toasts.current)
            .animation(.spring(duration: 0.35), value: player.hasCurrentTrack)
    }

    private var needsSharedArtwork: Bool {
        if #available(iOS 18.0, *) { return settings.showMainWindowAmbientBackground }
        return settings.showMainWindowAmbientBackground || player.showNowPlaying || legacyPlayerBackgroundActive
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if #available(iOS 18.0, *) {
            zoomNowPlayingRoot
        } else {
            legacyPresentationRoot
        }
    }

    @available(iOS 18.0, *)
    private var zoomNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying, onDismiss: finishPlayerDismissal) {
                systemNowPlayingPresentation
                    .navigationTransition(
                        .zoom(
                            sourceID: NowPlayingTransitionID.surface,
                            in: nowPlayingTransition
                        )
                    )
            }
    }

    @ViewBuilder
    private var systemNowPlayingPresentation: some View {
        if #available(iOS 16.4, *) {
            nowPlayingPresentation()
                .presentationBackground(.clear)
        } else {
            nowPlayingPresentation()
        }
    }

    private var legacyPresentationRoot: some View {
        appContent
            .background {
                LegacyPlayerSheet(
                    isPresented: $player.showNowPlaying,
                    onDismiss: finishPlayerDismissal,
                    content: nowPlayingPresentation(showsDismissIndicator: true)
                        .environment(\.nowPlayingBackgroundIsExternal, true)
                        .preferredColorScheme(.dark),
                    backdrop: NowPlayingFluidBackground(
                        artwork: artworkStore.artwork,
                        artworkKey: player.currentTrack?.album.picUrl,
                        colors: artworkStore.colors,
                        playing: player.isPlaying
                    )
                    .environment(\.colorScheme, resolvedColorScheme)
                )
            }
    }

    private func openPlayerDestination(_ destination: Destination) {
        guard player.showNowPlaying else {
            openDestination(destination)
            return
        }
        pendingPlayerDestination = { openDestination(destination) }
        player.showNowPlaying = false
    }

    private func finishPlayerDismissal() {
        legacyPlayerBackgroundActive = false
        let destination = pendingPlayerDestination
        pendingPlayerDestination = nil
        destination?()
    }

    @ViewBuilder
    private var appContent: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if #available(iOS 26.0, *) {
                NativeIPadRoot(path: $iPadPath)
            } else {
                LegacyIPadRoot(path: $iPadPath)
            }
        } else {
            tabInterface
                .overlay {
                    if settings.showMainWindowAmbientBackground {
                        MainWindowAmbientBackground(
                            colors: artworkStore.colors,
                            intensity: settings.mainWindowAmbientBackgroundIntensity
                        )
                        .ignoresSafeArea()
                    }
                }
        }
    }

    private func nowPlayingPresentation(
        showsDismissIndicator: Bool = true
    ) -> some View {
        IOSNowPlayingPresentation(
            isPresented: $player.showNowPlaying,
            showsDismissIndicator: showsDismissIndicator,
            deferDismissCompletion: { pendingPlayerDestination = $0 }
        ) {
            NowPlayingView(onOpenDestination: openPlayerDestination, backgroundColorScheme: resolvedColorScheme)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
        }
        .modifier(NowPlayingLoginPresenter())
    }

    @ViewBuilder
    private var tabInterface: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            iOS26TabInterface
        } else {
            customTabInterface
        }
        #else
        customTabInterface
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(MiniPlayerAccessoryModifier(
                transitionNamespace: nowPlayingTransition,
                colorScheme: resolvedColorScheme
            ))
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("推荐", systemImage: "house", value: .home) {
                tabStack(.home) { HomeView() }
            }
            Tab("精选", systemImage: "square.grid.2x2", value: .explore) {
                tabStack(.explore) { ExploreView() }
            }
            Tab("我的", systemImage: "person.crop.circle", value: .library) {
                tabStack(.library) { LibraryView(showLogin: $showLogin) }
            }
            Tab(value: .search, role: .search) {
                tabStack(.search) { SearchView(query: "").id(account.sessionRevision) }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }
    #endif

    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.home) { tabStack(.home) { HomeView() } }
                page(.explore) { tabStack(.explore) { ExploreView() } }
                page(.search) { tabStack(.search) { SearchView(query: "").id(account.sessionRevision) } }
                page(.library) { tabStack(.library) { LibraryView(showLogin: $showLogin) } }
            }

            legacyBottomBar
                .padding(.bottom, 6)
        }
        .background {
            LegacyTabScrollObserver(
                enabled: !player.showNowPlaying && !showLogin && !legacyKeyboardVisible,
                onCollapseChanged: setLegacyBarCollapsed
            )
        }
        .onChange(of: selectedTab) { tab in
            if tab != .search { lastLegacyMainTab = tab }
            setLegacyBarCollapsed(false)
        }
        .onChange(of: homePath) { _ in setLegacyBarCollapsed(false) }
        .onChange(of: explorePath) { _ in setLegacyBarCollapsed(false) }
        .onChange(of: searchPath) { _ in setLegacyBarCollapsed(false) }
        .onChange(of: libraryPath) { _ in setLegacyBarCollapsed(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            legacyKeyboardVisible = true
            setLegacyBarCollapsed(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            legacyKeyboardVisible = false
        }
    }

    /// Keep the three surfaces alive so layout animates between the same views,
    /// rather than fading out one hierarchy and inserting another from below.
    private var legacyBottomBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let expandedNavigationWidth = max(64, width - 76)
            let navigationWidth: CGFloat = legacyBarCollapsed ? 64 : expandedNavigationWidth
            let playerWidth = legacyBarCollapsed ? max(0, width - 152) : width

            ZStack(alignment: .bottomLeading) {
                GlassTabBar(
                    items: Self.tabItems,
                    selection: $selectedTab,
                    onReselect: popToRoot,
                    isCollapsed: legacyBarCollapsed,
                    expandedWidth: expandedNavigationWidth,
                    collapsedTab: lastLegacyMainTab,
                    onExpand: { setLegacyBarCollapsed(false) }
                )
                .frame(width: navigationWidth, height: 64)
                .scaleEffect(legacyBarCollapsed ? 52.0 / 64.0 : 1, anchor: .leading)

                IOSMiniPlayerBar(presentation: legacyBarCollapsed ? .compactOverlay : .legacyOverlay)
                    .frame(width: playerWidth, height: 52)
                    .nowPlayingTransitionSource(in: nowPlayingTransition)
                    .offset(x: legacyBarCollapsed ? 76 : 0, y: legacyBarCollapsed ? -6 : -72)

                LegacySearchTabButton(selection: $selectedTab, onReselect: popToRoot)
                    .scaleEffect(legacyBarCollapsed ? 52.0 / 64.0 : 1, anchor: .trailing)
                    .offset(x: width - 64)
            }
            .frame(width: width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .frame(height: legacyBarCollapsed ? 64 : 124)
        .padding(.horizontal, 12)
    }

    private func setLegacyBarCollapsed(_ collapsed: Bool) {
        guard legacyBarCollapsed != collapsed else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88)) {
            legacyBarCollapsed = collapsed
        }
    }

    private func popToRoot(_ tab: IOSTab) {
        switch tab {
        case .home: homePath = []
        case .explore: explorePath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        }
    }

    private func openDestination(_ destination: Destination) {
        player.showNowPlaying = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            iPadPath.appendIfNotCurrent(destination)
            return
        }

        let path = binding(for: selectedTab)
        var destinations = path.wrappedValue
        destinations.appendIfNotCurrent(destination)
        path.wrappedValue = destinations
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        NavigationStack(path: binding(for: tab)) {
            content().appDestinations()
        }
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }

    private func binding(for tab: IOSTab) -> Binding<[Destination]> {
        switch tab {
        case .home: return $homePath
        case .explore: return $explorePath
        case .search: return $searchPath
        case .library: return $libraryPath
        }
    }
}

extension IOSMainWindow {
    static let tabItems: [GlassTabBar.Item] = [
        .init(tab: .home, title: "推荐", icon: "house"),
        .init(tab: .explore, title: "精选", icon: "square.grid.2x2"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
        .init(tab: .library, title: "我的", icon: "person.crop.circle"),
    ]
}

private enum NowPlayingTransitionID {
    static let surface = "now-playing-surface"
}

/// Login requested from the player must be presented by the player itself:
/// the main window is already presenting its full-screen cover on iOS 18+.
/// Keeping this state here also makes cancellation return to the same player.
private struct NowPlayingLoginPresenter: ViewModifier {
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false

    func body(content: Content) -> some View {
        content
            .environment(\.openLogin, { showLogin = true })
            .sheet(isPresented: $showLogin) {
                LoginSheet()
                    .environmentObject(account)
            }
    }
}

// MARK: - Mini player bar for iOS

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let transitionNamespace: Namespace.ID
    let colorScheme: ColorScheme

    /// Always attached so the TabView keeps its identity: adding the
    /// accessory later would rebuild every tab on first playback.
    func body(content: Content) -> some View {
        content.tabViewBottomAccessory {
            IOSMiniPlayerAccessory(transitionNamespace: transitionNamespace)
                .environment(\.colorScheme, colorScheme)
        }
    }
}

@available(iOS 26.0, *)
private struct IOSMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let transitionNamespace: Namespace.ID

    var body: some View {
        IOSMiniPlayerBar(presentation: presentation)
            .nowPlayingTransitionSource(in: transitionNamespace)
    }

    private var presentation: IOSMiniPlayerBar.Presentation {
        let placementIsInline = placement.map { $0 == .inline }
        return NowPlayingPresentationMetrics.shouldUseInlineMiniPlayerLayout(
            placementIsInline: placementIsInline
        ) ? .inlineAccessory : .bottomAccessory
    }
}
#endif

extension View {
    @ViewBuilder
    func nowPlayingTransitionSource(in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(
                id: NowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            // Pre-18 presents full-screen with a slide transition (see
            // legacyPresentationRoot); no matched-geometry pairing needed.
            self
        }
    }
}

#endif
