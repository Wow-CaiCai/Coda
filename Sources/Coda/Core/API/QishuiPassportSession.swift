import Foundation
import Security
import WebKit

enum QishuiPassportError: LocalizedError {
    case initialization, missingSignature, network, invalidResponse, verificationCancelled, verificationUnavailable
    var errorDescription: String? {
        switch self {
        case .initialization: return "汽水登录安全组件未能加载，请稍后重试"
        case .missingSignature: return "汽水登录安全校验未就绪，已停止请求，请稍后重试"
        case .network: return "汽水登录连接失败，请检查网络后重试"
        case .invalidResponse: return "汽水登录返回了无法识别的数据"
        case .verificationCancelled: return "安全验证未完成，可以刷新二维码后重新登录"
        case .verificationUnavailable: return "汽水安全验证组件暂时不可用，请稍后重试"
        }
    }
}

/// One isolated WebKit cookie jar and official SDK instance per QR flow.
/// No external browser, helper server, copied SDK bundle, or relaxed CORS/TLS.
@MainActor
final class QishuiPassportSession: NSObject, WKNavigationDelegate {
    struct Response {
        let body: [String: Any]
        let cookieHeader: String
        let signatureLength: Int
        let msTokenLength: Int
        let browserInfoLength: Int
        let sessionTokenMatches: Bool
    }
    private let web: WKWebView
    private var initialization: Task<Void, Error>?
    private var navigation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var closed = false
    var verificationView: WKWebView { web }

    static func supportsPath(_ path: String) -> Bool {
        path.hasPrefix("/passport/web/") || path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "passport/safe/pack_verify_ways_data"
    }

    static func isOfficialVerificationURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return ["qishui.com", "zijieapi.com", "yhgfb-cn-static.com", "bytetos.com", "bytegoofy.com", "bytegecko.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    /// A per-flow client security seed, not an account credential. Initialize
    /// storage before loading the official SDK, then reuse it on every request.
    static func securitySeed() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 88)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw QishuiPassportError.initialization }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    func close() {
        closed = true
        initialization?.cancel()
        initialization = nil
        navigationTimeout?.cancel()
        web.evaluateJavaScript("window.codaCancelVerification?.(); window.codaActivePassportRequest?.abort()", completionHandler: nil)
        web.stopLoading()
        finishNavigation(.failure(CancellationError()))
    }

    private func prepare() async throws {
        guard !closed else { throw CancellationError() }
        if let initialization { try await initialization.value; return }
        let task = Task { @MainActor [self] in
            // The origin is the official API itself. A non-200 root document is
            // acceptable; all authentication XHRs remain same-origin.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigation = continuation
                navigationTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.web.stopLoading()
                    self?.finishNavigation(.failure(QishuiPassportError.initialization))
                }
                web.load(URLRequest(url: URL(string: "https://api.qishui.com/")!))
            }
            try Task.checkCancellation()
            do {
                let ready = try await web.callAsyncJavaScript(Self.bootstrap, arguments: ["securitySeed": try Self.securitySeed()], in: nil, contentWorld: .page)
                guard ready as? Bool == true else { throw QishuiPassportError.initialization }
            } catch is CancellationError { throw CancellationError() }
            catch { throw QishuiPassportError.initialization }
        }
        initialization = task
        try await task.value
    }

    func send(_ request: URLRequest) async throws -> Response {
        guard let url = request.url, url.scheme == "https", url.host == "api.qishui.com",
              Self.supportsPath(url.path) else { throw QishuiPassportError.invalidResponse }
        try await prepare()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        var headers = request.allHTTPHeaderFields ?? [:]
        // The browser owns cookies and its real User-Agent. Never inject a
        // simulated browser fingerprint or reuse another account's cookie jar.
        headers = headers.filter { !["cookie", "user-agent", "referer", "origin", "host", "content-length"].contains($0.key.lowercased()) }
        let cookies = await allCookies()
        let csrf = cookies.first { $0.name == "passport_csrf_token" } ?? cookies.first { $0.name == "passport_csrf_token_default" }
        headers["X-Tt-Passport-Csrf-Token"] = csrf?.value
        let arguments: [String: Any] = ["address": url.absoluteString, "method": request.httpMethod ?? "GET", "headers": headers,
            "body": request.httpBody.flatMap { String(data: $0, encoding: .utf8) } as Any? ?? NSNull()]
        let value: Any?
        do { value = try await web.callAsyncJavaScript(Self.sendScript, arguments: arguments, in: nil, contentWorld: .page) }
        catch is CancellationError { throw CancellationError() }
        catch { throw QishuiPassportError.network }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let response = value as? [String: Any] else { throw QishuiPassportError.invalidResponse }
        let signatureLength = (response["signatureLength"] as? NSNumber)?.intValue ?? 0
        // Only inspect field length, never expose/log the signed URL or SDK state.
        let msTokenLength = (response["msTokenLength"] as? NSNumber)?.intValue ?? 0
        let browserInfoLength = (response["browserInfoLength"] as? NSNumber)?.intValue ?? 0
        let tokenMatches = response["sessionTokenMatches"] as? Bool == true
        guard signatureLength == 44, msTokenLength == 120, browserInfoLength > 0, tokenMatches else { throw QishuiPassportError.missingSignature }
        let status = (response["status"] as? NSNumber)?.intValue ?? 0
        guard (200..<300).contains(status) else { throw QishuiPassportError.network }
        guard let text = response["text"] as? String, let bytes = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw QishuiPassportError.invalidResponse }
        let stored = await allCookies()
        let header = stored.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "qishui.com" || domain.hasSuffix(".qishui.com")
        }.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return .init(body: object, cookieHeader: header, signatureLength: signatureLength, msTokenLength: msTokenLength, browserInfoLength: browserInfoLength, sessionTokenMatches: tokenMatches)
    }

    func cancelVerification() {
        web.evaluateJavaScript("window.codaVerificationCancelled=true; window.codaCancelVerification?.()", completionHandler: nil)
    }

    func verify(_ decision: [String: Any], generalParameters: [String: String]) async throws {
        guard let address = decision["url"] as? String, let url = URL(string: address, relativeTo: URL(string: "https://api.qishui.com/"))?.absoluteURL, Self.isOfficialVerificationURL(url) else { throw QishuiPassportError.verificationUnavailable }
        var decision = decision
        decision["url"] = url.absoluteString
        try await prepare()
        guard !closed else { throw CancellationError() }
        do {
            let result = try await web.callAsyncJavaScript(Self.verificationScript, arguments: ["decision": decision, "general": generalParameters], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard let object = result as? [String: Any], object["status"] as? Bool == true else { throw QishuiPassportError.verificationCancelled }
        } catch is CancellationError { throw CancellationError() }
        catch QishuiPassportError.verificationCancelled { throw QishuiPassportError.verificationCancelled }
        catch { throw QishuiPassportError.verificationUnavailable }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(QishuiPassportError.initialization)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(QishuiPassportError.initialization)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(QishuiPassportError.initialization))
        initialization = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == false, let url = navigationAction.request.url, url.absoluteString == "about:blank" || Self.isOfficialVerificationURL(url) {
            decisionHandler(.allow); return
        }
        guard let url = navigationAction.request.url, url.scheme == "https", url.host == "api.qishui.com" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    private static let bootstrap = #"""
    if (location.origin !== 'https://api.qishui.com') throw new Error('origin');
    if (!/^[A-Za-z0-9_-]{118}==$/.test(securitySeed)) throw new Error('security context');
    localStorage.setItem('xmst', securitySeed);
    localStorage.setItem('xmsty', securitySeed);
    window.codaPassportToken = securitySeed;
    let estimate = {};
    try { estimate = await navigator.storage.estimate(); } catch (_) {}
    let storageSize = 0;
    for (let i = 0; i < localStorage.length; i++) storageSize += (localStorage.getItem(localStorage.key(i)) || '').length;
    let permissions = [];
    try {
        const permission = await navigator.permissions.query({name:'notifications'});
        permissions = [{name:'notifications',state:permission.state}];
    } catch (_) {}
    let graphics = {};
    try {
        const canvas = document.createElement('canvas');
        const gl = canvas.getContext('webgl');
        const extension = gl?.getExtension('WEBGL_debug_renderer_info');
        if (extension) graphics = {vendor:gl.getParameter(extension.UNMASKED_VENDOR_WEBGL),renderer:gl.getParameter(extension.UNMASKED_RENDERER_WEBGL)};
    } catch (_) {}
    const timing = performance.getEntriesByType('navigation')[0] || {};
    const context = {
        hardwareConcurrency:navigator.hardwareConcurrency, webdriver:Boolean(navigator.webdriver),
        chromedriver:typeof window.chromedriver !== 'undefined', shelldriver:typeof window.shelldriver !== 'undefined',
        plugins:navigator.plugins?.length || 0, permissions,
        innerHeight:window.innerHeight, innerWidth:window.innerWidth, outerHeight:window.outerHeight, outerWidth:window.outerWidth,
        stoargeStatus:{
            indexedDB:{idb:typeof indexedDB,open:typeof indexedDB?.open,indexedDB:typeof indexedDB,IDBKeyRange:typeof IDBKeyRange,
                openDatabase:typeof window.openDatabase,isSafari:/Safari/.test(navigator.userAgent) && !/Chrome/.test(navigator.userAgent),hasFetch:typeof fetch === 'function'},
            localStorage:{isSupportLStorage:true,size:storageSize,write:true},
            storageQuotaStatus:{usage:estimate.usage,quota:estimate.quota,isPrivate:Boolean(estimate.quota && estimate.quota < 120000000)}
        },
        webgl:graphics, notificationPermission:window.Notification?.permission || 'none',
        performance:{timeOrigin:performance.timeOrigin,usedJSHeapSize:performance.memory?.usedJSHeapSize || 'unsupport',
            navigationTiming:{decodedBodySize:timing.decodedBodySize,entryType:timing.entryType,initiatorType:timing.initiatorType,
                name:timing.name,renderBlockingStatus:timing.renderBlockingStatus,serverTiming:(timing.serverTiming||[]).map(t=>t.name).join(','),guleStart:'none',guleDuration:'none'}},
        request_host:'resources', request_pathname:'/main.asar/main.html',
        browser:{t:String(Date.now()).split('').reverse().join(''),bit_protocol:'false',bit_helper:false}
    };
    const bytes = new TextEncoder().encode(JSON.stringify(context));
    window.codaPassportSourceInfo = Array.from(bytes,b=>(b^5).toString(16)).join('');
    window.codaPassportSignatureLength = 0;
    const nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, address) {
        const parsed = new URL(address, location.href);
        if (parsed.origin === location.origin && (parsed.pathname.startsWith('/passport/web/') || parsed.pathname.startsWith('/passport/safe/pack_verify_ways_data'))) {
            window.codaPassportSignatureLength = (parsed.searchParams.get('a_bogus') || '').length;
            window.codaPassportTokenLength = (parsed.searchParams.get('msToken') || '').length;
            window.codaPassportTokenMatches = parsed.searchParams.get('msToken') === window.codaPassportToken;
        }
        return nativeOpen.apply(this, arguments);
    };
    await new Promise((resolve, reject) => {
        const script = document.createElement('script');
        const timeout = setTimeout(() => reject(new Error('sdk timeout')), 15000);
        script.src = 'https://lf-headquarters-speed.yhgfb-cn-static.com/obj/rc-client-security/web/stable/1.0.0.41/bdms.js';
        script.onload = () => { clearTimeout(timeout); resolve(); };
        script.onerror = () => { clearTimeout(timeout); reject(new Error('sdk unavailable')); };
        document.head.appendChild(script);
    });
    if (typeof window.bdms?.init !== 'function') throw new Error('sdk unavailable');
    await window.bdms.init({aid: 386088, paths: ['/passport']});
    return true;
    """#

    private static let sendScript = #"""
    const destination = new URL(address);
    if (destination.origin !== location.origin || !(destination.pathname.startsWith('/passport/web/') || destination.pathname.startsWith('/passport/safe/pack_verify_ways_data'))) throw new Error('destination');
    if (!window.codaPassportToken || !window.codaPassportSourceInfo) throw new Error('security context');
    destination.searchParams.set('msToken',window.codaPassportToken);
    destination.searchParams.set('account_sdk_source_info',window.codaPassportSourceInfo);
    window.codaPassportSignatureLength = 0;
    window.codaPassportTokenLength = 0;
    window.codaPassportTokenMatches = false;
    return await new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        window.codaActivePassportRequest = xhr;
        xhr.open(method, destination.href, true);
        xhr.withCredentials = true;
        xhr.timeout = 20000;
        for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, String(value));
        xhr.onload = () => resolve({status:xhr.status,text:xhr.responseText,signatureLength:window.codaPassportSignatureLength,
            msTokenLength:window.codaPassportTokenLength,browserInfoLength:window.codaPassportSourceInfo.length,sessionTokenMatches:window.codaPassportTokenMatches});
        xhr.onerror = () => reject(new Error('network'));
        xhr.onabort = () => reject(new Error('cancelled'));
        xhr.ontimeout = () => reject(new Error('timeout'));
        xhr.send(body === null ? null : body);
    });
    """#

    /// Official verification UI executes in the same origin and cookie jar as
    /// the QR flow. Only the user can complete its CAPTCHA/SMS/other challenge.
    private static let verificationScript = #"""
    window.codaVerificationCancelled=false;
    const resource = new URL(decision.url);
    const allowed = ['qishui.com','zijieapi.com','yhgfb-cn-static.com','bytetos.com','bytegoofy.com','bytegecko.com'];
    if (resource.protocol !== 'https:' || !allowed.some(h=>resource.hostname===h || resource.hostname.endsWith('.'+h))) throw new Error('verification origin');
    const load = (address, integrity) => new Promise((resolve,reject)=>{
        const script = document.createElement('script');
        script.src=address;
        if (integrity) {script.integrity=integrity;script.crossOrigin='anonymous';}
        const timeout=setTimeout(()=>reject(new Error('component timeout')),15000);
        script.onload=()=>{clearTimeout(timeout);resolve();};
        script.onerror=()=>{clearTimeout(timeout);reject(new Error('component unavailable'));};
        document.head.appendChild(script);
    });
    if (!window.React) await load('https://unpkg.com/react@17.0.2/umd/react.production.min.js','sha256-Ipu/TQ50iCCVZBUsZyNJfxrDk0E2yhaEIz0vqI+kFG8=');
    if (!window.ReactDOM) await load('https://unpkg.com/react-dom@17.0.2/umd/react-dom.production.min.js','sha256-nbMykgB6tsOFJ7OdVmPpdqMFVk4ZsqWocT6issAPUF0=');
    window.ucSecondVerifyReact=window.React;
    window.ucSecondVerifyReactDom=window.ReactDOM;
    let event={};
    if (typeof decision.event_params==='string') {try{event=JSON.parse(decision.event_params);}catch(_){}}
    else if (decision.event_params && typeof decision.event_params==='object') event=decision.event_params;
    resource.searchParams.set('aid','386088');
    resource.searchParams.set('verify_reason',String(event.verify_reason||''));
    resource.searchParams.set('verify_scene',String(event.verify_scene||''));
    window.$$account_verify_portrait_id=String(decision.verify_portrait_id||'');
    if (typeof window.ucWebSecondVerify!=='function') await load(resource.href);
    if (typeof window.ucWebSecondVerify!=='function') throw new Error('verification unavailable');
    if (window.codaVerificationCancelled) return {status:false};
    document.body.replaceChildren();
    return await new Promise(resolve=>{
        let finished=false;
        const timer=setTimeout(()=>finish({status:false}),600000);
        const finish=result=>{
            if(finished)return;
            finished=true;clearTimeout(timer);window.codaCancelVerification=null;
            resolve({status:result?.status===true});
        };
        window.codaCancelVerification=()=>finish({status:false});
        window.ucWebSecondVerify({
            ...decision,aid:386088,isNewVerifyUI:true,event_params:event,generalParams:general,
            verifyFinishCallback:finish,
            newSecondVerifyWebOptions:{host:'https://api.qishui.com',verifyAppName:'汽水音乐移动端'},
            newSecondVerificationCall:{reportAppLog:()=>{}},
            fun:decision.verify_from==='verify_center'?'verify_center':'verify',uc_account_verify_version:'1.0.29',
            monitorTime:{startTime:Date.now(),fetchEndTime:Date.now(),scriptLoadStartTime:0,scriptLoadEndTime:Date.now(),renderStartTime:Date.now()}
        });
    });
    """#
}
