import SwiftUI
import CoreImage.CIFilterBuiltins

struct PlatformLoginSheet: View {
    let provider: MusicProvider
    /// Adds the scanned account to the list instead of switching to it.
    var addsAccount = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @State private var image: PlatformImage?
    @State private var qqChannel = QQMusicLoginChannel.qq
    @State private var status = "正在获取二维码…"
    @State private var refresh = UUID()
    @State private var isSaving = false
    @StateObject private var qishuiAuth = QishuiMusicAPI(diagnostics: true)
    @StateObject private var qqAuth = QQMusicAuth(persistsSession: false)
    @State private var pending: PendingQR?
    @State private var isWaiting = false
    @State private var resumeOnNextRun = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            Text(addsAccount ? "添加\(provider.name)账号" : "登录\(provider.name)").font(Theme.Typography.sectionTitle)
                .padding(.top, Theme.Spacing.section)
            if provider == .qq {
                Picker("扫码方式", selection: $qqChannel) {
                    ForEach(QQMusicLoginChannel.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(isSaving)
                .onChange(of: qqChannel) { _ in refresh = UUID() }
            }
            Text(provider == .qishui ? "请使用已登录的汽水音乐 App 扫码并确认登录" : provider == .bodian ? "请使用波点音乐 App 扫码并确认登录" : provider == .qq ? "请使用\(qqChannel.name)扫描二维码并确认登录" : "请使用酷狗音乐扫描二维码并确认登录")
                .font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginQRCodeFrame(image: image) { EmptyView() }
            Text(status).font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #if os(iOS)
            if let singleDeviceHint {
                Text(singleDeviceHint)
                    .font(Theme.Typography.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }
            #endif
            Button("刷新二维码") { refresh = UUID() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                .disabled(isSaving)
            Button("取消") { dismiss() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.section).disabled(isSaving)
        }
        .frame(width: 320)
        .interactiveDismissDisabled(isSaving)
        .task(id: refresh) { await login() }
        .onDisappear {
            if provider == .qishui { qishuiAuth.cancelLogin() }
            if provider == .bodian, case .bodian(let key) = pending { BodianMusicAPI.shared.cancelLogin(key) }
            #if os(iOS)
            endBackgroundTask()
            #endif
        }
        .onChange(of: scenePhase) { phase in
            #if os(iOS)
            updateBackgroundTask(for: phase)
            #endif
            if phase == .active { resumeIfNeeded() }
        }
        .sheet(isPresented: Binding(get: { qishuiAuth.verificationWebView != nil }, set: { if !$0 { qishuiAuth.cancelVerification() } })) {
            if let web = qishuiAuth.verificationWebView {
                QishuiSecurityVerificationView(webView: web, onCancel: { qishuiAuth.cancelVerification() })
            }
        }
    }
    /// The QR a poll or wait loop is attached to; kept across app switches so
    /// returning from the official app resumes the same code instead of a new one.
    private enum PendingQR: Equatable {
        case qq
        case kugou(String)
        case bodian(String)
        case qqMusic(QQMusicAdditionalLogin.MusicAppQR)
    }

    private enum PollResult {
        case waiting, scanned, expired
        case error(String)
        case success([String: String], String)
    }

    /// Consecutive transient failures tolerated while the app is backgrounded.
    private static let maxTransientFailures = 15

    private func login() async {
        let resume = resumeOnNextRun && pending != nil
        resumeOnNextRun = false
        if !resume {
            pending = nil
            image = nil
            status = "正在获取二维码…"
        }
        isWaiting = true
        defer { isWaiting = false }
        do {
            if provider == .qishui { try await loginQishui(); return }
            if provider == .qq, qqChannel == .wechat {
                let result = try await QQMusicAdditionalLogin.wechat(onImage: { data in
                    image = PlatformImage(data: data)
                    status = "等待使用微信扫码"
                }, onScanned: {
                    status = "已扫码，请在微信中确认"
                })
                try Task.checkCancellation()
                await finish(credentials: result.credentials, nickname: result.nickname)
                return
            }
            let qr: PendingQR
            if resume, let pending {
                qr = pending
            } else {
                qr = try await makeQR()
                try Task.checkCancellation()
                pending = qr
            }
            if case .qqMusic(let app) = qr { try await waitQQMusic(app) } else { try await poll(qr) }
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { status = error.localizedDescription } }
    }

    private func makeQR() async throws -> PendingQR {
        if provider == .qq, qqChannel == .qqmusic {
            // Shown on subscription, so a scan is never missed before the topic is live.
            return .qqMusic(try await QQMusicAdditionalLogin.createMusicAppQR())
        }
        if provider == .qq {
            let data = try await qqAuth.fetchQRCode()
            try Task.checkCancellation()
            image = PlatformImage(data: data)
            status = "等待扫码"
            return .qq
        }
        if provider == .bodian {
            let qr = try await BodianMusicAPI.shared.qrCode()
            try Task.checkCancellation()
            image = Self.qrImage(qr.scanURL.absoluteString)
            status = "等待使用波点音乐扫码"
            return .bodian(qr.key)
        }
        let qr = try await KugouMusicAPI.shared.qrKey()
        try Task.checkCancellation()
        image = Self.qrImage(qr.url)
        status = "等待扫码"
        return .kugou(qr.key)
    }

    /// Polls the QQ / KuGou QR, riding out network errors from being backgrounded.
    private func poll(_ qr: PendingQR) async throws {
        var failures = 0
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3))
            let result: PollResult
            do {
                result = try await pollOnce(qr)
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures >= Self.maxTransientFailures { throw error }
                continue
            }
            try Task.checkCancellation()
            switch result {
            case .waiting: status = "等待扫码"
            case .scanned: status = "已扫码，请在\(provider == .qq ? "QQ" : provider == .bodian ? "波点音乐" : "酷狗音乐")中确认"
            case .expired: pending = nil; status = "二维码已过期，请刷新"; return
            case .error(let message): pending = nil; status = message; return
            case .success(let credentials, let nickname):
                pending = nil
                await finish(credentials: credentials, nickname: nickname)
                return
            }
        }
    }

    private func pollOnce(_ qr: PendingQR) async throws -> PollResult {
        switch qr {
        case .qq:
            switch try await qqAuth.poll() {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .expired: return .expired
            case .error(let message): return .error(message)
            case .success(let nickname): return .success(qqAuth.exportedCredentials, nickname)
            }
        case .kugou(let key):
            switch try await KugouMusicAPI.shared.pollQR(key: key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .expired: return .expired
            case .error(let message): return .error(message)
            case .success(let credentials): return .success(credentials, credentials["nickname"] ?? "酷狗音乐用户")
            }
        case .bodian(let key):
            switch try await BodianMusicAPI.shared.pollQRCode(key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .expired: return .expired
            case .confirmed(let credentials): return .success(credentials, credentials["nickname"] ?? "波点音乐用户")
            }
        case .qqMusic:
            return .error("QQ 音乐 App 二维码不支持轮询")
        }
    }

    /// Waits on the QQ Music App QR, reconnecting with the same code after the
    /// socket drops (e.g. while the user confirms in QQ Music on this device).
    private func waitQQMusic(_ qr: QQMusicAdditionalLogin.MusicAppQR) async throws {
        var failures = 0
        var scanned = false
        while true {
            if qr.isExpired { pending = nil; status = "二维码已过期，请刷新"; return }
            do {
                let result = try await QQMusicAdditionalLogin.waitMusicApp(qr, onSubscribed: {
                    failures = 0
                    image = PlatformImage(data: qr.image)
                    status = scanned ? "已扫码，请在 QQ 音乐 App 中确认" : "等待使用 QQ 音乐 App 扫码"
                }, onScanned: {
                    scanned = true
                    status = "已扫码，请在 QQ 音乐 App 中确认"
                })
                try Task.checkCancellation()
                pending = nil
                await finish(credentials: result.credentials, nickname: result.nickname)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where Self.isTransient(error) {
                failures += 1
                if failures >= Self.maxTransientFailures { throw error }
                try await Task.sleep(for: .seconds(2))
            } catch {
                pending = nil
                throw error
            }
        }
    }

    /// Connection-level failures (worth reconnecting) versus answers from the
    /// service such as expiry or cancellation (final).
    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case ProviderRequestError.network = error { return true }
        let domain = (error as NSError).domain
        return domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain
    }

    /// Picks up the pending QR when coming back from the official app.
    private func resumeIfNeeded() {
        guard !isWaiting, let pending, !isSaving else { return }
        if case .qqMusic(let app) = pending, app.isExpired { return }
        resumeOnNextRun = true
        refresh = UUID()
    }

    /// Same-device hint for channels whose official app hasn't been confirmed
    /// to accept a QR picked from the photo library.
    private var singleDeviceHint: String? {
        let app: String
        switch provider {
        case .qq:
            switch qqChannel {
            case .wechat: return "微信可能不支持从相册识别登录二维码，可能同时需要另一个设备用以登录"
            case .qq: app = "QQ"
            case .qqmusic: app = "QQ 音乐 App"
            }
        case .kugou: app = "酷狗音乐 App"
        case .bodian: app = "波点音乐 App"
        default: return nil
        }
        return "只有一台设备？截图二维码，到\(app)的扫一扫里从相册识别，然后回到这里。尚未确认是否支持相册识别，可能同时需要另一个设备用以登录"
    }

    #if os(iOS)
    /// Keeps polling / the socket alive briefly while the user is in the official app.
    private func updateBackgroundTask(for phase: ScenePhase) {
        if phase == .background, pending != nil, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Music account QR login") {
                endBackgroundTask()
            }
        } else if phase == .active {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func loginQishui() async throws {
        let qr = try await qishuiAuth.qrCode()
        try Task.checkCancellation()
        guard let decoded = Self.qrImage(qr.scanURL.absoluteString) else { throw QishuiError.invalidResponse }
        image = decoded
        status = "等待使用汽水音乐扫码"
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3))
            if qishuiAuth.isQRCodeExpired(token: qr.token) { status = "二维码已过期，请刷新"; return }
            let state = try await qishuiAuth.pollQRCode(token: qr.token)
            try Task.checkCancellation()
            switch state {
            case .waiting: status = "等待使用汽水音乐扫码"
            case .scanned: status = "已扫码，请在汽水音乐中确认"
            case .processing: status = "正在等待平台完成登录，请稍候…"
            case .expired: status = "二维码已过期，请刷新"; return
            case .confirmed(let credentials):
                await finish(credentials: credentials, nickname: credentials["nickname"] ?? "汽水音乐用户")
                return
            }
        }
    }
    private func finish(credentials: [String: String], nickname: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            if addsAccount {
                let item = try await MusicAccountManager.shared.addAccount(provider: provider, credentials: credentials, nickname: nickname)
                ToastCenter.shared.show(MusicAccountManager.shared.addedMessage(for: item))
            } else {
                try await MusicAccountManager.shared.saveAndActivate(provider: provider, credentials: credentials, nickname: nickname)
            }
            dismiss()
        } catch { status = error.localizedDescription }
    }
    private static func qrImage(_ value: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
