import Foundation
import os.log

/// One imported LX Music custom-source script.
struct CustomSource: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var summary: String
    var version: String
    var author: String
    var homepage: String
    var script: String
    /// Where an online import came from, for re-downloading.
    var sourceURL: String?
    var isEnabled: Bool
    var importedAt: Date
    /// Platforms and tiers from the last successful load, shown before loading again.
    var capabilities: [String: [String]]?

    var info: [String: String] {
        ["name": name, "description": summary, "version": version, "author": author,
         "homepage": homepage, "rawScript": script]
    }
}

/// The user's imported audio sources: stored in Application Support, tried in
/// list order before the built-in platforms. Scripts are evaluated only when a
/// track needs them or the settings page is open.
@MainActor
final class CustomSourceStore: ObservableObject {
    static let shared = CustomSourceStore()

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum ImportError: LocalizedError {
        case empty, tooLarge, notScript, invalidURL, download(Int)

        var errorDescription: String? {
            switch self {
            case .empty: return String(localized: "文件为空")
            case .tooLarge: return String(localized: "脚本超过 5 MB")
            case .notScript: return String(localized: "不是有效的音源脚本")
            case .invalidURL: return String(localized: "请输入 http 或 https 链接")
            case .download(let status): return String(localized: "下载失败（HTTP \(status)）")
            }
        }
    }

    static let maximumScriptSize = 5 * 1024 * 1024
    private static let log = Logger(subsystem: "wow.caicai.coda", category: "custom-source")

    @Published private(set) var sources: [CustomSource] = []
    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var updateNotices: [String: LXScriptRuntime.UpdateNotice] = [:]

    private var runtimes: [String: LXScriptRuntime] = [:]
    private var loading: [String: Task<LXScriptRuntime.Capabilities, Error>] = [:]
    private let fileURL: URL

    init(fileURL: URL = CodaDirectories.applicationSupport("CustomSources").appendingPathComponent("sources.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([CustomSource].self, from: data) {
            sources = stored
        }
    }

    var enabledSources: [CustomSource] { sources.filter(\.isEnabled) }
    var hasEnabledSources: Bool { sources.contains(where: \.isEnabled) }

    // MARK: - Import

    /// Imports a script file; an existing source with the same name is replaced.
    @discardableResult
    func importScript(_ data: Data, fileName: String, sourceURL: String? = nil) async throws -> CustomSource {
        guard !data.isEmpty else { throw ImportError.empty }
        guard data.count <= Self.maximumScriptSize else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ImportError.notScript
        }
        let source = try upsert(script: text, fallbackName: (fileName as NSString).deletingPathExtension, sourceURL: sourceURL)
        _ = try? await capabilities(of: source.id)
        return source
    }

    /// Adds or replaces (by name) a source without loading it.
    @discardableResult
    private func upsert(script text: String, fallbackName: String, sourceURL: String?, isEnabled: Bool? = nil) throws -> CustomSource {
        guard !text.isEmpty else { throw ImportError.empty }
        guard text.utf8.count <= Self.maximumScriptSize else { throw ImportError.tooLarge }
        guard text.contains("lx") else { throw ImportError.notScript }
        let header = Self.header(of: text)
        let name = header["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (fallbackName.isEmpty ? String(localized: "未命名音源") : fallbackName)
        let existing = sources.firstIndex { $0.name == String(name.prefix(48)) }
        let source = CustomSource(
            id: existing.map { sources[$0].id } ?? UUID().uuidString,
            name: String(name.prefix(48)),
            summary: String((header["description"] ?? "").prefix(200)),
            version: String((header["version"] ?? "").prefix(24)),
            author: String((header["author"] ?? "").prefix(48)),
            homepage: String((header["homepage"] ?? "").prefix(200)),
            script: text,
            sourceURL: sourceURL,
            isEnabled: isEnabled ?? existing.map { sources[$0].isEnabled } ?? true,
            importedAt: Date(),
            capabilities: nil)
        if let existing {
            sources[existing] = source
        } else {
            sources.append(source)
        }
        unload(source.id)
        save()
        return source
    }

    // MARK: - Clipboard

    private struct Export: Codable {
        struct Item: Codable {
            let name: String?
            let script: String
            let sourceURL: String?
            let isEnabled: Bool
        }
        var format = Self.formatName
        var version = 1
        let sources: [Item]
        static let formatName = "coda.custom-sources"
    }

    /// Every source, in order, with its script and on/off state.
    func exportData() throws -> String {
        let export = Export(sources: sources.map { .init(name: $0.name, script: $0.script, sourceURL: $0.sourceURL, isEnabled: $0.isEnabled) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }

    /// Imports an export from `exportData`, a single script, or download links
    /// (one per line). Returns how many sources were added or replaced.
    func importData(_ text: String) async throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }
        if let data = trimmed.data(using: .utf8),
           let export = try? JSONDecoder().decode(Export.self, from: data), export.format == Export.formatName {
            var count = 0
            for item in export.sources {
                if (try? upsert(script: item.script, fallbackName: item.name ?? "", sourceURL: item.sourceURL, isEnabled: item.isEnabled)) != nil {
                    count += 1
                }
            }
            guard count > 0 else { throw ImportError.notScript }
            Task { await loadEnabled() }
            return count
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.allSatisfy({ $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }) {
            var count = 0
            var lastError: Error?
            for line in lines {
                do { _ = try await importOnline(line); count += 1 } catch { lastError = error }
            }
            if count == 0, let lastError { throw lastError }
            return count
        }
        let source = try upsert(script: trimmed, fallbackName: "", sourceURL: nil)
        _ = try? await capabilities(of: source.id)
        return 1
    }

    func importOnline(_ address: String) async throws -> CustomSource {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ImportError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.download(http.statusCode)
        }
        return try await importScript(data, fileName: url.lastPathComponent, sourceURL: url.absoluteString)
    }

    /// Reads `@name`, `@version` and similar tags from the leading comment block.
    nonisolated static func header(of script: String) -> [String: String] {
        guard let start = script.range(of: "/*"), let end = script.range(of: "*/", range: start.upperBound..<script.endIndex),
              script[script.startIndex..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [:] }
        var fields: [String: String] = [:]
        for line in script[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "* \t!"))
            guard trimmed.hasPrefix("@") else { continue }
            let parts = trimmed.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let key = parts.first, fields[String(key)] == nil else { continue }
            fields[String(key)] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        return fields
    }

    // MARK: - Editing

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        if !enabled { unload(id) }
        save()
        Task { await UnblockFailureMemory.shared.removeAll() }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func remove(_ id: String) {
        unload(id)
        sources.removeAll { $0.id == id }
        statuses[id] = nil
        updateNotices[id] = nil
        save()
    }

    func reload(_ id: String) async {
        unload(id)
        _ = try? await capabilities(of: id)
    }

    /// Loads every enabled script so the settings page can show what each offers.
    func loadEnabled() async {
        await withTaskGroup(of: Void.self) { group in
            for source in enabledSources where runtimes[source.id] == nil && loading[source.id] == nil {
                group.addTask { _ = try? await self.capabilities(of: source.id) }
            }
        }
    }

    // MARK: - Runtimes

    /// The loaded runtime and its declared platforms, loading the script on first use.
    func runtime(for id: String) async throws -> (LXScriptRuntime, LXScriptRuntime.Capabilities) {
        let capabilities = try await capabilities(of: id)
        guard let runtime = runtimes[id] else { throw LXScriptRuntime.RuntimeError.notLoaded }
        return (runtime, capabilities)
    }

    @discardableResult
    private func capabilities(of id: String) async throws -> LXScriptRuntime.Capabilities {
        if let task = loading[id] { return try await task.value }
        guard let source = sources.first(where: { $0.id == id }) else { throw LXScriptRuntime.RuntimeError.notLoaded }
        if runtimes[id] != nil { return source.capabilities ?? [:] }

        let runtime = LXScriptRuntime(name: source.name)
        runtime.onUpdateNotice = { [weak self] notice in
            Task { @MainActor in self?.updateNotices[id] = notice }
        }
        statuses[id] = .loading
        let task = Task { try await runtime.load(script: source.script, info: source.info) }
        loading[id] = task
        defer { loading[id] = nil }
        do {
            let capabilities = try await task.value
            // A newer import or removal replaced this load while it ran.
            guard sources.first(where: { $0.id == id })?.script == source.script else {
                runtime.close()
                throw LXScriptRuntime.RuntimeError.notLoaded
            }
            runtimes[id] = runtime
            statuses[id] = capabilities.isEmpty ? .failed(String(localized: "脚本没有声明可用的平台")) : .ready
            if let index = sources.firstIndex(where: { $0.id == id }), sources[index].capabilities != capabilities {
                sources[index].capabilities = capabilities
                save()
            }
            return capabilities
        } catch {
            runtime.close()
            if sources.contains(where: { $0.id == id }) {
                statuses[id] = .failed(error.localizedDescription)
            }
            Self.log.error("load script=\(source.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func unload(_ id: String) {
        loading[id]?.cancel()
        loading[id] = nil
        runtimes.removeValue(forKey: id)?.close()
        statuses[id] = .idle
        updateNotices[id] = nil
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sources)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("save error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
