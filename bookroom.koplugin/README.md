# Book Room KOReader plugin

This is the Phase 2 Step 8 plugin. It reads KOReader's current
table-of-contents title, normalizes the active document TOC, checks whether the
existing KOSync configuration is ready for Book Room, automatically observes
chapter changes, and retains the manual `Send chapter now` action.

This build is deliberately limited to external chapter observation:

- no KOSync credential writes, display, or logging
- no modification of KOSync configuration
- no request for page turns within the same normalized chapter
- at most one latest pending automatic observation per document
- no Book Room progress updates
- no mapping to Book Room work units
- no book text, annotations, highlights, or notes access

## Device installation

1. Connect the Kobo to a computer.
2. From the Book Room repository, run
   `./integrations/koreader/scripts/install-plugin.sh`.
3. Wait for the installer to report that every file was verified.
4. Safely eject the Kobo and restart KOReader.
5. Open an EPUB with a table of contents.
6. Open KOReader's reader menu and select `Tools` > `More tools` > `Book Room`.

The installer defaults to `/Volumes/KOBOeReader`; pass a different mounted
volume path as its first argument if necessary. Do not extract the ZIP directly
over the live plugin directory. Kobo's FAT filesystem can orphan an overwritten
file if a copy or disconnect is interrupted. The verified installer preserves
the old live file until the replacement is complete, explicitly flushes each
replacement, and compares the installed bytes with the source.

The document-state module is named `docstate.lua`, which fits FAT's native 8.3
filename format and does not share the colliding `kosync_` prefix that was
repeatedly recovered by filesystem repair as `FSCK0000.000` on the test Kobo.

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
`LuaSettings` API. It never retains, displays, or logs the userkey, never
displays the username, and never writes or flushes the KOSync settings object.
The username is used only to partition Book Room's local observation state so
pending documents cannot cross KOSync accounts. A connected result displays
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

The plugin uses KOReader's lua-Spore transport with the same 2-second block
and 5-second total timeout convention as the built-in KOSync manual progress
push. On Kobo, where `DUSE_TURBO_LIB` is disabled, Spore uses KOReader's
LuaSocket/LuaSec fallback. Platforms with a Turbo looper remain asynchronous.
It does not retry or queue a failed observation.

The document digest, progress, percentage, device name, and device ID follow
KOReader 2026.07.1's built-in KOSync logic. The success message displays the
non-secret digest temporarily so the real Kobo test can confirm that Sense and
Sensibility uses `f668708f3aa2f8779f57665ded56ed38` and attaches to its existing
Phase 1 row.

Step 7 was verified on the real Kobo with KOReader 2026.07.1: the manual send
returned HTTP 200 and displayed that expected document digest.

## Automatic chapter observation

KOReader's `ReaderReady`, `PageUpdate`, and `PosUpdate` events schedule a
next-tick inspection using the existing chapter extractor and normalized TOC.
The complete normalized chapter identity is compared with the last locally
observed identity for the current document. Changes in live page, XPointer, or
percentage inside the same TOC entry therefore do not send another request.
Both forward and backward chapter transitions send the same Step 7 payload.

Automatic observation never prompts to enable Wi-Fi. Offline changes are
persisted in `settings/bookroom_observations.lua`, with a single replaceable
pending payload per KOSync user and document. `NetworkConnected` silently sends
the latest pending value. Failed sends remain pending, do not retry on ordinary
page events, and never show a user-facing error dialog.

The observation file contains no userkey. This milestone does not map TOC
entries, update `user_work_progress`, or change spoiler/unlock state.

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
- `Spore.new_from_lua()` and KOReader's standard LuaSocket/LuaSec fallback
- KOReader's asynchronous `httpclient` when a Turbo looper is available
- `NetworkMgr:willRerunWhenOnline(callback)`
- `NetworkMgr:isOnline()` for silent automatic observation
- `onReaderReady`, `onPageUpdate`, `onPosUpdate`, and `onNetworkConnected`
- `Persist:new{ codec = "dump" }` for latest pending observation state
- `socketutil:set_timeout(2, 5)`
- `rapidjson.encode()` and `rapidjson.null`

No KOReader source is patched or monkey-patched.
