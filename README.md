# KOReader integration

`bookroom.koplugin` is Book Room's independent KOReader extension. It is kept
separate from the Fastify KOSync implementation and does not patch KOReader's
built-in progress-sync plugin.

## Package the plugin

Run:

```sh
./integrations/koreader/scripts/package-plugin.sh
```

The command creates `integrations/koreader/dist/bookroom.koplugin.zip`. The ZIP
has `bookroom.koplugin/` as its root directory, ready to extract into KOReader's
`plugins` directory.

The packaging command verifies every archived file byte-for-byte against the
tested source tree before publishing the ZIP.

## Install on a mounted Kobo

With the Kobo mounted at `/Volumes/KOBOeReader`, run:

```sh
./integrations/koreader/scripts/install-plugin.sh
```

An alternative mount path can be passed as the first argument. The installer
copies each file through a FAT-safe temporary filename, flushes the volume,
verifies the staged bytes, atomically renames that file into place, flushes
again, and verifies the live bytes. Always safely eject the Kobo afterward.

Use this installer instead of extracting or overwriting the plugin directly on
the Kobo. It leaves each previous live file intact until its replacement has
been fully copied and verified.

## Local checks

With `texlua` and `texluac` available, run:

```sh
./integrations/koreader/scripts/test-plugin.sh
```

This parses the plugin's Lua files and exercises the isolated chapter extractor,
TOC normalizer, read-only KOSync credential status, latest-observation state,
diagnostic view, and reader lifecycle/menu callbacks against mocked KOReader
objects.

The checks also run the verified installer twice against a temporary mock Kobo
volume, confirming both first installation and safe replacement.

## Phase 2 Step 6 server endpoint

The API accepts a current external chapter observation at:

```text
PUT /bookroom/v1/chapter-progress
```

The endpoint uses the existing KOSync `x-auth-user` and `x-auth-key` headers.
It stores the observation on the existing `koreader_documents` row identified
by authenticated user plus document digest. When that row does not exist, the
request's required Phase 1 progress/device fields create a minimal document;
an existing row keeps its standard KOSync progress fields unchanged.

Step 6 added server support only. The Step 7 plugin below now calls that
endpoint manually; no chapter-to-Book-Room-unit mapping or Book Room progress
update occurs.

## Phase 2 Step 7 manual send

The reader plugin now adds `Send chapter now` inside the standard `Book Room`
submenu. The action reuses the existing extractor, normalized current TOC
entry, KOSync settings, and KOReader 2026.07.1 document identity logic. It sends
one request to the fixed Book Room endpoint and reports a concise on-device
success, credential, network, or server result.

The Step 7 action remains a forced manual request. Its success view temporarily
includes the non-secret document digest for the real Kobo identity acceptance
check.

Real-Kobo verification passed on KOReader 2026.07.1: the manual action returned
HTTP 200 and displayed the expected Phase 1 document digest
`f668708f3aa2f8779f57665ded56ed38`. The client uses KOReader's lua-Spore
transport so the Kobo build, where Turbo is disabled, follows KOSync's
LuaSocket/LuaSec fallback.

## Phase 2 Step 8 automatic observation

The plugin listens to KOReader's reader-ready, page-update, position-update,
and network-connected events. Duplicate page/position events are collapsed to
one next-tick observation, then the existing extractor and TOC normalizer
compare the complete normalized chapter identity with the last locally
observed chapter for that KOSync user and document.

A page turn inside the same chapter performs no request or network check.
Forward and backward chapter changes send the same Step 7 payload. While
offline, `settings/bookroom_observations.lua` retains only the latest unsent
payload per document; a later chapter replaces the older pending value.
`NetworkConnected` silently flushes pending observations. Automatic failures
remain pending and never display a reader dialog or retry on subsequent pages.

This state contains no userkey. Automatic observation only updates the external
KOReader chapter record through `/bookroom/v1/chapter-progress`; it performs no
chapter mapping, canonical Book Room progress update, or spoiler/unlock change.

## Phase 2 Step 9 read-only presentation

The authenticated integration document list exposes the latest stored external
chapter as a small `currentChapter` read model containing its exact KOReader
title and observation time. The KOReader settings page presents three separate
values for each synced document:

- KOReader percentage
- current KOReader chapter
- canonical Book Room progress for the linked work

An unavailable observation is shown as `Not available`. This display does not
map TOC entries, write `user_work_progress`, or change spoiler/unlock state.
