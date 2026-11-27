import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import os.log
import Security

/// Runs one imported LX Music custom-source script in its own JavaScript
/// context. The script only sees `globalThis.lx` from `LXHostPreload`; network
/// access goes through an ephemeral, cookie-free session owned here.
///
/// All JavaScript runs on `queue`, so the context is never touched from two
/// threads at once.
final class LXScriptRuntime: @unchecked Sendable {
    /// Platform code (`wy`, `tx`, `kg`, `kw`, `mg`) → the quality tokens the
    /// script declares for `musicUrl`.
    typealias Capabilities = [String: [String]]

    struct UpdateNotice: Sendable, Equatable {
        let log: String
        let url: URL?
    }

    enum RuntimeError: LocalizedError {
        case unavailable
        case script(String)
        case initTimedOut
        case requestTimedOut
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "无法创建脚本运行环境")
            case .script(let message): return message
            case .initTimedOut: return String(localized: "脚本未在限定时间内完成初始化")
            case .requestTimedOut: return String(localized: "音源请求超时")
            case .notLoaded: return String(localized: "音源脚本未加载")
            }
        }
    }

    static let initTimeout: TimeInterval = 12
    static let callTimeout: TimeInterval = 15
    private static let log = Logger(subsystem: "wow.caicai.coda", category: "custom-source")
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    let name: String
    var onUpdateNotice: (@Sendable (UpdateNotice) -> Void)?

    private let queue = DispatchQueue(label: "wow.caicai.coda.custom-source")
    private let session: URLSession
    private let key = UUID().uuidString
    private var context: JSContext?
    private var initContinuation: CheckedContinuation<Capabilities, Error>?
    private var calls: [String: CheckedContinuation<String, Error>] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var isClosed = false

    init(name: String) {
        self.name = name
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Evaluates the script and waits for its `inited` event.
    func load(script: String, info: [String: String]) async throws -> Capabilities {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Capabilities, Error>) in
            queue.async { [self] in
                guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
                    continuation.resume(throwing: RuntimeError.unavailable)
                    return
                }
                context.name = "Coda custom source: \(name)"
                context.exceptionHandler = { [name] context, exception in
                    // Keep it readable through `context.exception`, like the default handler.
                    context?.exception = exception
                    Self.log.error("script=\(name, privacy: .public) exception=\(exception?.toString() ?? "", privacy: .public)")
                }
                self.context = context
                initContinuation = continuation
                installHost(in: context)
                context.evaluateScript(LXHostPreload.script)
                context.objectForKeyedSubscript("__coda_setup__")?.call(withArguments: [key, info])
                if let error = takeException(context) {
                    finishInit(.failure(RuntimeError.script(String(localized: "运行环境初始化失败：\(error)"))))
                    return
                }
                context.evaluateScript(script)
                if let error = takeException(context) {
                    finishInit(.failure(RuntimeError.script(String(localized: "脚本错误：\(error)"))))
                    return
                }
                queue.asyncAfter(deadline: .now() + Self.initTimeout) { [weak self] in
                    self?.finishInit(.failure(RuntimeError.initTimedOut))
                }
            }
        }
    }

    /// Asks the script for a playable URL.
    func musicURL(platform: String, quality: String, musicInfo: [String: Any]) async throws -> String {
        let id = UUID().uuidString
        let payload: [String: Any] = [
            "id": id, "source": platform, "action": "musicUrl",
            "info": ["type": quality, "musicInfo": musicInfo],
        ]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    guard context != nil, !isClosed else {
                        continuation.resume(throwing: RuntimeError.notLoaded)
                        return
                    }
                    calls[id] = continuation
                    callJS("call", payload)
                    queue.asyncAfter(deadline: .now() + Self.callTimeout) { [weak self] in
                        self?.finishCall(id, .failure(RuntimeError.requestTimedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { [weak self] in self?.finishCall(id, .failure(CancellationError())) }
        }
    }

    /// Stops every request and releases the context.
    func close() {
        queue.async { [self] in
            isClosed = true
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            finishInit(.failure(RuntimeError.notLoaded))
            for id in Array(calls.keys) { finishCall(id, .failure(RuntimeError.notLoaded)) }
            context = nil
        }
    }

    // MARK: - Queue-confined helpers

    private func finishInit(_ result: Result<Capabilities, Error>) {
        guard let continuation = initContinuation else { return }
        initContinuation = nil
        if case .failure = result { context = nil }
        continuation.resume(with: result)
    }

    private func finishCall(_ id: String, _ result: Result<String, Error>) {
        calls.removeValue(forKey: id)?.resume(with: result)
    }

    private func takeException(_ context: JSContext) -> String? {
        guard let exception = context.exception else { return nil }
        context.exception = nil
        return exception.toString()
    }

    private func callJS(_ action: String, _ payload: Any) {
        guard let context, !isClosed,
              let function = context.objectForKeyedSubscript("__coda_native__"), !function.isUndefined,
              let json = Self.json(payload) else { return }
        function.call(withArguments: [key, action, json])
        if let error = takeException(context) {
            Self.log.error("script=\(self.name, privacy: .public) callback=\(action, privacy: .public) error=\(error, privacy: .public)")
        }
    }

    private static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Host functions

    private func installHost(in context: JSContext) {
        let consoleLog: @convention(block) () -> Void = { [name] in
            let message = (JSContext.currentArguments() ?? []).compactMap { ($0 as? JSValue)?.toString() }.joined(separator: " ")
            Self.log.debug("script=\(name, privacy: .public) \(message, privacy: .public)")
        }
        let console = JSValue(newObjectIn: context)
        for level in ["log", "info", "warn", "error", "debug"] {
            console?.setObject(consoleLog, forKeyedSubscript: level as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let host = JSValue(newObjectIn: context)
        let call: @convention(block) (String, String, String) -> Void = { [weak self] key, action, payload in
            guard let self, key == self.key else { return }
            self.handle(action, payload)
        }
        let setTimeout: @convention(block) (String, Int, Double) -> Void = { [weak self] key, id, delay in
            guard let self, key == self.key else { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(min(max(0, delay), 600_000)))) { [weak self] in
                self?.callJS("timer", id)
            }
        }
        let md5: @convention(block) (String) -> String = { text in
            Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let aes: @convention(block) (String, String, String, String) -> String? = { data, key, iv, mode in
            Self.aesEncrypt(data: data, key: key, iv: iv, mode: mode)
        }
        let rsa: @convention(block) (String, String) -> String? = { data, key in
            Self.rsaEncrypt(data: data, publicKey: key)
        }
        host?.setObject(call, forKeyedSubscript: "call" as NSString)
        host?.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        host?.setObject(md5, forKeyedSubscript: "md5" as NSString)
        host?.setObject(aes, forKeyedSubscript: "aesEncrypt" as NSString)
        host?.setObject(rsa, forKeyedSubscript: "rsaEncrypt" as NSString)
        context.setObject(host, forKeyedSubscript: "__coda_host__" as NSString)
    }

    private func handle(_ action: String, _ payload: String) {
        let object = payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        let data = object as? [String: Any] ?? [:]
        switch action {
        case "inited":
            let sources = data["sources"] as? [String: Any] ?? [:]
            var capabilities: Capabilities = [:]
            for (platform, value) in sources {
                guard let value = value as? [String: Any],
                      (value["actions"] as? [String] ?? []).contains("musicUrl") else { continue }
                capabilities[platform] = value["qualitys"] as? [String] ?? []
            }
            finishInit(.success(capabilities))
        case "reply":
            guard let id = data["id"] as? String else { return }
            if data["ok"] as? Bool == true, let url = data["url"] as? String {
                finishCall(id, .success(url))
            } else {
                finishCall(id, .failure(RuntimeError.script(data["error"] as? String ?? String(localized: "音源没有返回有效地址"))))
            }
        case "request":
            perform(data)
        case "cancel":
            if let id = data["id"] as? String { tasks.removeValue(forKey: id)?.cancel() }
        case "updateAlert":
            let notice = UpdateNotice(log: data["log"] as? String ?? "",
                                      url: (data["updateUrl"] as? String).flatMap(URL.init(string:)))
            onUpdateNotice?(notice)
        default:
            break
        }
    }

    private func perform(_ data: [String: Any]) {
        guard let id = data["id"] as? String else { return }
        guard let address = data["url"] as? String, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            callJS("response", ["id": id, "error": "Invalid URL"])
            return
        }
        var request = URLRequest(url: url)
        let method = (data["method"] as? String ?? "GET").uppercased()
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let timeout = data["timeout"] as? Double, timeout > 0 { request.timeoutInterval = min(timeout / 1000, 60) }
        for (field, value) in data["headers"] as? [String: Any] ?? [:] {
            request.setValue(String(describing: value), forHTTPHeaderField: field)
        }
        if let body = data["body"], !(body is NSNull) {
            if let text = body as? String {
                request.httpBody = Data(text.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        } else if let form = (data["form"] as? [String: Any]) ?? (data["formData"] as? [String: Any]) {
            request.httpBody = Data(Self.formEncoded(form).utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if let form = data["formData"] as? String {
            request.httpBody = Data(form.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        let binary = data["binary"] as? Bool == true
        let task = session.dataTask(with: request) { [weak self] body, response, error in
            self?.queue.async { [weak self] in
                guard let self, self.tasks.removeValue(forKey: id) != nil else { return }
                if let error {
                    self.callJS("response", ["id": id, "error": error.localizedDescription])
                    return
                }
                let http = response as? HTTPURLResponse
                let body = body ?? Data()
                var payload: [String: Any] = [
                    "statusCode": http?.statusCode ?? 0,
                    "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                    "headers": (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
                        $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
                    },
                ]
                if binary {
                    payload["bodyBase64"] = body.base64EncodedString()
                } else if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
                          json is [String: Any] || json is [Any] {
                    payload["body"] = json
                } else {
                    payload["body"] = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
                }
                self.callJS("response", ["id": id, "response": payload])
            }
        }
        tasks[id] = task
        task.resume()
    }

    private static func formEncoded(_ form: [String: Any]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let text = String(describing: value).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(text)"
        }.joined(separator: "&")
    }

    // MARK: - Crypto for lx.utils

    /// `aes-128-cbc` uses PKCS#7 padding; `aes-128-ecb` uses none, like LX.
    static func aesEncrypt(data: String, key: String, iv: String, mode: String) -> String? {
        guard let input = Data(base64Encoded: data), let keyData = Data(base64Encoded: key) else { return nil }
        let isCBC = mode.lowercased().contains("cbc")
        let ivData = isCBC ? (Data(base64Encoded: iv) ?? Data(count: kCCBlockSizeAES128)) : Data()
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let options = CCOptions(isCBC ? kCCOptionPKCS7Padding : kCCOptionECBMode)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, keyData.count, isCBC ? ivBytes.baseAddress : nil,
                                inBytes.baseAddress, input.count, out.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written).base64EncodedString()
    }

    /// Raw (no padding) RSA with a PEM or bare Base64 public key, like LX.
    static func rsaEncrypt(data: String, publicKey: String) -> String? {
        let body = publicKey
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let input = Data(base64Encoded: data), var der = Data(base64Encoded: body) else { return nil }
        der = stripSubjectPublicKeyInfo(der)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return nil }
        let blockSize = SecKeyGetBlockSize(key)
        var padded = Data(count: max(0, blockSize - input.count))
        padded.append(input.suffix(blockSize))
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, nil) else { return nil }
        return (encrypted as Data).base64EncodedString()
    }

    /// SecKey wants PKCS#1; PEM public keys are usually X.509 SubjectPublicKeyInfo.
    private static func stripSubjectPublicKeyInfo(_ der: Data) -> Data {
        let bytes = [UInt8](der)
        // The SPKI header for RSA ends with the BIT STRING tag 0x03, length, 0x00.
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        guard let oidRange = bytes.firstRange(of: rsaOID) else { return der }
        var index = oidRange.upperBound
        while index < bytes.count, bytes[index] != 0x03 { index += 1 }
        guard index + 1 < bytes.count else { return der }
        index += 1
        if bytes[index] & 0x80 != 0 { index += Int(bytes[index] & 0x7f) }
        index += 2 // length byte and the unused-bits byte
        return index < bytes.count ? Data(bytes[index...]) : der
    }
}
