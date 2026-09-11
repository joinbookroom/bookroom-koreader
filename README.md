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
`plugins` directory. It also copies the same verified artifact to
`apps/web/public/downloads/bookroom.koplugin.zip` for the settings-page download.

The packaging command uses a fixed file order, strips host-specific ZIP
metadata, verifies every archived file byte-for-byte against the tested source
tree, and prints its SHA-256 checksum. Repeating it against an unchanged source
tree produces the same artifact.

The beta plugin version is `0.6.0`. It is present in KOReader plugin metadata,
the in-reader About view, every chapter-observation payload, and the Book Room
settings read model after a 0.6.0 observation arrives.

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
volume, confirming both first installation and safe replacement. Sentinel
KOSync and Book Room observation settings are verified unchanged after both
installs.

## Install or update manually

1. Download `bookroom.koplugin.zip` from Book Room's KOReader settings page.
2. Connect the Kobo over USB and open `.adds/koreader/plugins` on the device.
3. Extract or copy the archive so the result is
   `.adds/koreader/plugins/bookroom.koplugin`.
4. For an update, replace the files in that plugin folder only. Leave
   `.adds/koreader/settings/kosync.lua` and
   `.adds/koreader/settings/bookroom_observations.lua` in place.
5. Safely eject the Kobo and restart KOReader. Open
   `Book Room` > `About Book Room` to confirm version 0.6.0.

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

This state contains no userkey. Automatic observation updates the external
KOReader chapter record through `/bookroom/v1/chapter-progress`; it never
updates canonical Book Room progress or spoiler/unlock state.

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

## Phase 2 Step 10 canonical mapping

Chapter observations now include KOReader's complete normalized external TOC.
The API fingerprints that structure and stores its raw titles, indexes, and
paths separately from Book Room reading units. For a confirmed document-to-Work
link, deterministic exact-title and explicit `Chapter N` matches are persisted
as `EXACT`; repeated or competing candidates are `AMBIGUOUS`; and entries with
no credible canonical unit remain `UNMAPPED`.

Valid Roman chapter numerals are parsed strictly, while plain numbers and
labels such as `Part 2`, `Book 3`, or `Volume II` are not treated as chapters.
Changing the TOC fingerprint invalidates mappings tied to the previous external
structure. The authenticated settings page shows the mapping review and allows
an entry to be explicitly confirmed against one reading unit. This mapping
layer does not write `user_work_progress`, completion state, unlock state, or
message visibility.

## Phase 2 Step 11 trusted progress baseline

Each linked document can now establish a deliberate baseline between its exact
current chapter mapping and the reader's canonical Book Room position. If
KOReader is ahead, the settings page requires an explicit confirmation and
delegates the change to Book Room's existing reading-position service. Equal
positions, or a Book Room position already ahead, establish the baseline
without mutating canonical progress.

The management read model exposes whether the baseline is enabled and a pure
transition decision: baseline required, no change, adjacent forward, forward
jump requiring confirmation, backward/rereading, Book Room already ahead, or
unusable mapping. Decisions use the ordered canonical reading units rather
than chapter-title parsing or ordinal arithmetic. A TOC change, linked-Work
change, or relevant remapping clears the baseline; disabling it preserves
KOSync, observations, mappings, and Book Room progress.

Step 11 deliberately does not consume an adjacent-forward decision. Automatic
plugin observations can update the displayed KOReader chapter and decision,
but cannot move canonical progress. Entering the final canonical unit uses the
normal `reading` position semantics and never invokes the explicit Finished
action.

## Phase 2 Step 12 adjacent automatic progress

After a chapter observation is stored and mapped, the API now re-evaluates the
latest canonical progress and sync baseline. It automatically delegates to the
existing Book Room reading-position service only when synchronization is
enabled, the baseline remains established, the current mapping is exact, and
the pure transition decision is `ADJACENT_FORWARD`.

The guarded reading-position call compares the expected current canonical unit
while holding the existing progress-row lock. A retry therefore sees
`NO_CHANGE`, while a concurrent position change makes the stale automatic move
a safe no-op. Sequential adjacent observations advance normally. Large jumps,
backward movement, Book Room positions already ahead, missing baselines, and
ambiguous or unmapped chapters never perform an automatic write.

The observation endpoint returns a lightweight `canonicalProgress` outcome and
emits safe structured events for advances, blocked jumps, and concurrency
skips. Automatic entry into the final reading unit retains the normal
`reading` status and does not create a completion. The existing KOReader plugin
request and response handling are unchanged.

Meaningful KOReader chapter states also use Book Room's existing notification
inbox and realtime invalidation channel. Adjacent automatic advances, forward
jumps, backward divergence, unusable mappings, and sync invalidations each
share one notification card per document and event type. A durable state key
makes retries of the same unresolved state a no-op; a genuinely different
chapter state refreshes and reopens the card. Forward jumps, mapping review,
and invalidation link to the affected settings card, while backward/rereading
notifications are informational only. Page turns and same-chapter observations
do not produce notifications.
