## Add Book Room plugin

Book Room observes KOReader chapter changes and sends the latest normalized
chapter and table of contents to the user's Book Room account through the
existing KOSync connection. It does not patch KOReader or access book text,
annotations, highlights, or notes.

Upstream plugin repository:
https://github.com/anushkafka/bookroom-koreader

Compatibility:

- verified with KOReader 2026.07.1 on Kobo;
- requires the Book Room KOSync-compatible service;
- checks required APIs at runtime and fails open when they are unavailable.

The upstream repository includes installation and privacy documentation,
isolated Lua tests, a verified Kobo installer, reproducible release archives,
and an AGPL-3.0 license. Its `koreader-contrib` branch exposes the plugin files
at the repository root for this submodule.
