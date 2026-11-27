import Foundation
import Testing
@testable import CodaCore

@Suite("Custom source tests")
struct CustomSourceTests {
    /// A self-contained script: no network, but it exercises init, the request
    /// event, timers and the crypto/buffer helpers.
    private static let script = #"""
    /**
     * @name Fixture Source
     * @description For tests
     * @version 1.2.0
     * @author Coda
     */
    const { EVENT_NAMES, on, send, utils } = globalThis.lx
    on(EVENT_NAMES.request, ({ source, action, info }) => new Promise((resolve, reject) => {
      if (action !== 'musicUrl') return reject(new Error('unsupported'))
      setTimeout(() => {
        const md5 = utils.crypto.md5('abc')
        const b64 = utils.buffer.bufToString(utils.buffer.from('音源'), 'base64')
        const back = utils.buffer.bufToString(utils.buffer.from(b64, 'base64'), 'utf8')
        resolve(`https://example.com/${source}/${info.musicInfo.songmid}?q=${info.type}&md5=${md5}&b64=${encodeURIComponent(b64)}&back=${encodeURIComponent(back)}`)
      }, 5)
    }))
    send(EVENT_NAMES.inited, {
      sources: {
        wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
        kw: { name: 'kw', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
        tx: { name: 'tx', type: 'lyric', actions: ['lyric'], qualitys: [] },
      },
    })
    """#

    @Test func readsTheScriptHeader() {
        let header = CustomSourceStore.header(of: Self.script)
        #expect(header["name"] == "Fixture Source")
        #expect(header["version"] == "1.2.0")
        #expect(header["author"] == "Coda")
        #expect(CustomSourceStore.header(of: "const a = 1 /* @name Late */").isEmpty)
    }

    @Test func runsAnLXScript() async throws {
        let runtime = LXScriptRuntime(name: "fixture")
        defer { runtime.close() }
        let capabilities = try await runtime.load(script: Self.script, info: ["name": "Fixture Source"])
        #expect(capabilities == ["wy": ["128k", "320k", "flac"], "kw": ["128k"]])
        let address = try await runtime.musicURL(platform: "wy", quality: "flac", musicInfo: ["songmid": "42"])
        let url = try #require(URLComponents(string: address))
        #expect(url.path == "/wy/42")
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["q"] == "flac")
        #expect(query["md5"] == "900150983cd24fb0d6963f7d28e17f72")
        #expect(query["b64"] == Data("音源".utf8).base64EncodedString())
        #expect(query["back"] == "音源")
    }

    @Test func reportsScriptErrors() async {
        let runtime = LXScriptRuntime(name: "broken")
        defer { runtime.close() }
        await #expect(throws: LXScriptRuntime.RuntimeError.self) {
            _ = try await runtime.load(script: "throw new Error('boom')", info: [:])
        }
    }

    @Test func picksTheClosestDeclaredTier() {
        let declared = ["128k", "320k", "flac"]
        #expect(CustomUnblockSource.token(for: .standard, declared: declared) == "128k")
        #expect(CustomUnblockSource.token(for: .exhigh, declared: declared) == "320k")
        #expect(CustomUnblockSource.token(for: .hires, declared: declared) == "flac")
        #expect(CustomUnblockSource.token(for: .lossless, declared: ["320k"]) == "320k")
        #expect(CustomUnblockSource.token(for: .standard, declared: ["flac"]) == "flac")
        #expect(CustomUnblockSource.token(for: .lossless, declared: []) == "flac")
    }

    @Test func triesTheTracksOwnPlatformFirst() {
        let declared: LXScriptRuntime.Capabilities = ["wy": [], "tx": [], "kg": [], "kw": []]
        #expect(CustomUnblockSource.platforms(for: .qq, declared: declared) == ["tx", "wy", "kg"])
        #expect(CustomUnblockSource.platforms(for: .qishui, declared: declared) == ["wy", "tx", "kg"])
        #expect(CustomUnblockSource.platforms(for: .netease, declared: ["kg": []]) == ["kg"])
    }

    @Test @MainActor func importsReplaceSourcesWithTheSameName() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("custom-sources-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CustomSourceStore(fileURL: file)
        let first = try await store.importScript(Data(Self.script.utf8), fileName: "fixture.js")
        let second = try await store.importScript(Data(Self.script.utf8), fileName: "fixture.js")
        #expect(store.sources.count == 1)
        #expect(first.id == second.id)
        #expect(store.sources[0].capabilities?["wy"] == ["128k", "320k", "flac"])
        #expect(CustomSourceStore(fileURL: file).sources.map(\.name) == ["Fixture Source"])
        await #expect(throws: CustomSourceStore.ImportError.self) {
            _ = try await store.importScript(Data("hello".utf8), fileName: "x.txt")
        }
        store.remove(first.id)
        #expect(store.sources.isEmpty)
    }

    @Test @MainActor func clipboardExportRoundTrips() async throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("custom-sources-\(UUID().uuidString).json")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("custom-sources-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let source = CustomSourceStore(fileURL: first)
        let imported = try await source.importScript(Data(Self.script.utf8), fileName: "fixture.js")
        let untitled = "const { EVENT_NAMES, send } = globalThis.lx\nsend(EVENT_NAMES.inited, { sources: {} })"
        try await source.importScript(Data(untitled.utf8), fileName: "我的音源.js")
        source.setEnabled(imported.id, false)
        let exported = try source.exportData()

        let target = CustomSourceStore(fileURL: second)
        #expect(try await target.importData(exported) == 2)
        #expect(target.sources.map(\.name) == ["Fixture Source", "我的音源"])
        #expect(target.sources.map(\.isEnabled) == [false, true])
        // A pasted script imports as one source.
        #expect(try await target.importData(Self.script) == 1)
        #expect(target.sources.count == 2)
        await #expect(throws: CustomSourceStore.ImportError.self) { _ = try await target.importData("   ") }
    }

    @Test func versionKeepsASingleV() {
        func source(_ version: String, _ author: String = "") -> CustomSource {
            CustomSource(id: "x", name: "x", summary: "", version: version, author: author, homepage: "",
                         script: "", sourceURL: nil, isEnabled: true, importedAt: Date(), capabilities: nil)
        }
        #expect(CustomSourcesSection.detail(source("5")) == "v5")
        #expect(CustomSourcesSection.detail(source("v5", "w")) == "v5 · w")
        #expect(CustomSourcesSection.detail(source("V3.0.0")) == "V3.0.0")
        #expect(CustomSourcesSection.detail(source("")) == nil)
    }
}
