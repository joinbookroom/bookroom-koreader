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

## Local checks

With `texlua` and `texluac` available, run:

```sh
./integrations/koreader/scripts/test-plugin.sh
```

This parses the plugin's Lua files and exercises the isolated chapter extractor,
TOC normalizer, read-only KOSync credential status, diagnostic view, and
reader-menu callbacks against mocked KOReader objects.

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

There are no page-turn hooks, retries, queues, timers, or automatic chapter
requests in this step. The success view temporarily includes the non-secret
document digest for the real Kobo identity acceptance check.
