# Book Room KOReader plugin

This is the Phase 2 Step 7 plugin. It reads KOReader's current
table-of-contents title, normalizes the active document TOC, checks whether the
existing KOSync configuration is ready for Book Room, and provides a manual
`Send chapter now` action.

This build is deliberately manual-only:

- no KOSync credential writes, display, or logging
- no modification of KOSync configuration
- no automatic, queued, background, or page-turn chapter requests
- no Book Room progress updates
- no mapping to Book Room work units
- no book text, annotations, highlights, or notes access

## Device installation

1. Connect the Kobo to a computer.
2. Copy the complete `bookroom.koplugin` directory to:
   `/mnt/onboard/.adds/koreader/plugins/bookroom.koplugin/`
3. Safely eject the Kobo and restart KOReader.
4. Open an EPUB with a table of contents.
5. Open KOReader's reader menu and select `Tools` > `More tools` > `Book Room`.

The Book Room submenu shows the current chapter, connection status, manual send
action, and temporary TOC diagnostics.

For the temporary Step 4 device diagnostic, select `Tools` > `More tools` >
`Book Room TOC diagnostics (temporary)`. A scrollable view shows:

- the current chapter from the proven Step 3 extractor
- every raw field name and Lua type observed across the active `ReaderToc.toc`
- the current raw entry's field values
- the normalized current entry and a five-entry sample around it

The normalized representation contains zero-based `index` and `depth`, plus
`title`, derived `parentIndex`, full title `path`, KOReader `seq_in_level` as
`sequenceInLevel`, and KOReader `page` and `xpointer` (as `location`) when
available. It exists only in memory.

## KOSync status

Select `Tools` > `More tools` > `Book Room sync status` while a document is
open. The result is connected only when all of these are present:

- the custom server is exactly `https://sync.joinbookroom.com`
- a non-empty KOSync username
- a non-empty KOSync userkey

The plugin reads KOReader 2026.07.1's `settings/kosync.lua` through KOReader's
`LuaSettings` API. It does not retain, display, or log the username or userkey,
and it never writes or flushes the settings object. A connected result displays
only the fixed hostname `sync.joinbookroom.com`.

The plugin detects the KOReader APIs it needs at runtime. When those APIs are
unavailable, it displays an unavailable status and does not interfere with
opening or reading the book.

## Manual chapter send

`Send chapter now` is enabled only when a normalized current TOC entry exists
and the existing KOSync connection is valid for the exact Book Room server.
One tap sends one authenticated `PUT` request to:

```text
https://sync.joinbookroom.com/bookroom/v1/chapter-progress
```

The plugin uses KOReader's asynchronous HTTP client with the same 2-second
block and 5-second total timeout convention as the built-in KOSync manual
progress push. It does not retry or queue a failed observation.

The document digest, progress, percentage, device name, and device ID follow
KOReader 2026.07.1's built-in KOSync logic. The success message displays the
non-secret digest temporarily so the real Kobo test can confirm that Sense and
Sensibility uses `f668708f3aa2f8779f57665ded56ed38` and attaches to its existing
Phase 1 row.

The minimum supported KOReader version will be documented after this milestone
is tested against the version installed on the target Kobo Clara. On the Kobo,
the version is available from `Help` > `About KOReader` (menu placement may vary).

## APIs used in this milestone

- `ReaderUI:getCurrentPage()`
- `ReaderToc:getTocTitleByPage(current_page)`
- `ReaderToc:fillToc()` and the resulting active `ReaderToc.toc`
- `ReaderToc:getTocIndexByPage(current_page, toc_chapter_title_bind_to_ticks)`
- `ReaderMenu:registerToMainMenu(plugin)`
- `TextViewer:new{...}` for the temporary scrollable diagnostic
- `DataStorage:getSettingsDir()`
- `LuaSettings:open(settings_dir .. "/kosync.lua")`
- `LuaSettings:readSetting("settings", {})`
- `DocSettings:readSetting("partial_md5_checksum")`
- `Paging:getLastProgress()` / `Rolling:getLastProgress()`
- `Paging:getLastPercent()` / `Rolling:getLastPercent()`
- `G_reader_settings:readSetting("device_id")`
- `Device.model` and KOSync's optional `kosync_hostname`
- KOReader's asynchronous `httpclient`
- `NetworkMgr:willRerunWhenOnline(callback)`
- `socketutil:set_timeout(2, 5)`
- `rapidjson.encode()` and `rapidjson.null`

No KOReader source is patched or monkey-patched.
