# Bodian (波点音乐) protocol reference

Sources:

- [Mintcolour/bodian-music-api](https://github.com/Mintcolour/bodian-music-api), npm package `bodian-music-api@0.1.2`, GNU Affero General Public License, version 3. The package was extracted from [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major) (AGPL-3.0); Coda checked the integration notes in folia-major at `d88a6f0` (`docs/bodian.md`, `sources/bodian`).
- The package's own NOTICE credits [MoeclubM/PyBodian](https://github.com/MoeclubM/PyBodian/commit/79ed7e25234efa07f4a5445ca10fdf06acedba0d) for identifying `authType` 10 in the QR flow.

`Sources/Coda/Core/API/BodianMusicAPI.swift` is a Swift adaptation of that package's request signing (`src/http.cjs`), QR login (`src/auth.cjs`), catalog paging (`src/catalog.cjs`), library and playlist edits (`src/library.cjs`, `src/mutations.cjs`), playback rights (`src/playback.cjs`) and word-timing lyric decoding (`src/lyrics.cjs`). The adaptation retains the upstream AGPL-3.0 license. No JavaScript is bundled or run.

Differences from the package:

- URLSession cannot send a body with GET. The signed playback GETs send their parameters in the query only and are signed over the query, which the service accepts.
- Decoded word timings are emitted in Coda's YRC line format; a timestamp repeated on the next line is read as that line's translation.
- Preview-only songs are not played; playback looks for the song on other sources instead.

## Bowen

`Sources/Coda/Core/API/BodianCatalog.swift` follows the endpoint notes of [ldm0715/bowen_music](https://github.com/ldm0715/bowen_music) at `a6eb46d` (GPL-3.0; `src/Bowen.Core/Api/Endpoints.cs`, `BodianApi.cs` and the request DTOs): the home module types of `service/home/index` and `service/home/aiPlaylistDetail`, charts (`service/home/bangNew`, `service/bang/{id}/musics`), album / artist / playlist search and suggestions, playlist categories, playlist create / delete / edit on `service/playlist`, `service/collect` writes and `collect/multipleState`, followed artists, Android-header comments and the `ucenter/users/pub` membership tiers. The Swift code is written independently from those notes; no C# is bundled. GPL-3.0 code may be combined with Coda's AGPL-3.0 under section 13 of both licenses.

Differences: comment pages are always requested at 30 rows (smaller sizes return short pages); AI playlists and charts are presented as Coda playlists and cannot be saved.

The service is not affiliated with Coda. Bodian playback is limited to mainland China networks.
