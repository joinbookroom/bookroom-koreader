# Changelog

All notable changes to Book Room for KOReader are documented here. Versions
follow [Semantic Versioning](https://semver.org/).

## [0.6.0] - 2026-09-12

### Added

- Manual and automatic chapter observation using the existing KOSync account.
- Normalized full-table-of-contents payloads for Book Room chapter mapping.
- Latest-only offline queue and silent send on network reconnection.
- Reader menu views for status, current chapter, diagnostics, and version.
- Verified, FAT-safe Kobo installer and isolated Lua test suite.

### Security and privacy

- KOSync credentials are read without modifying their settings file.
- Sync passwords are excluded from plugin storage, UI messages, and logs.
- The plugin does not access book text, annotations, highlights, or notes.

[0.6.0]: https://github.com/anushkafka/bookroom-koreader/releases/tag/v0.6.0
