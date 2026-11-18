# Changelog

每个版本必须在此记录变更；发布流程会提取对应版本的段落，作为 GitHub Release
正文并渲染进 Sparkle appcast 的更新说明。段落格式：`## <版本号> - <日期>`，条目必须写成单行。

每个版本先写完整的**英文**部分（`### Added` / `### Fixed` / `### Improved`），再用一条
`---` 分隔，随后是完整的**中文**部分（`### 新增` / `### 修复` / `### 改进`）。英文块与中文块
的条目一一对应、顺序一致。

## 0.1.0 - 2026-11-10

### Added

- First public release of Coda, an independently maintained fork of Kumone: a native SwiftUI music client for macOS 15+ and iOS/iPadOS 16+.
- Multiple music services: NetEase Cloud Music, QQ Music, KuGou and Qishui (capabilities vary by service).
- One responsive player interface that adapts to window sizes, device sizes and orientations, with synced lyrics, romaji and furigana.
- Automix transitions, audio spectrum and CarPlay support.
- Unsigned iOS IPA for AltStore / SideStore, with an AltStore source for updates.

### Improved

- Separate bundle identifiers, data, caches and Keychain services for release (`wow.caicai.coda`) and development (`wow.caicai.coda.dev`) builds, so Coda never touches Kumone data.
- The Mac build is ad-hoc signed and not notarized; see the install notes for the first launch.

---

### 新增

- Coda 首个公开版本：基于 Kumone 独立维护的原生 SwiftUI 音乐客户端，支持 macOS 15+ 与 iOS/iPadOS 16+。
- 接入网易云音乐、QQ 音乐、酷狗音乐和汽水音乐，各平台能力不同。
- 单一响应式播放界面，适配窗口、设备尺寸与横竖屏，支持歌词同步、罗马音与假名注音。
- 支持自动混音过渡、音频频谱与 CarPlay。
- 提供未签名 iOS IPA，可通过 AltStore / SideStore 安装，并提供 AltStore 更新源。

### 改进

- 正式版（`wow.caicai.coda`）与开发版（`wow.caicai.coda.dev`）使用独立的应用标识、数据、缓存与钥匙串。
- Mac 版采用 ad-hoc 签名且未经公证，首次打开请参考安装说明。
