# Book Room for KOReader

Book Room for KOReader observes chapter changes in KOReader and sends the
latest chapter to [Book Room](https://joinbookroom.com). It uses the credentials
and document identity from KOReader's built-in Progress Sync integration; it
does not patch or replace Progress Sync.

The plugin is currently beta software. Version **0.6.0** has been verified with
**KOReader 2026.07.1** on Kobo. Other KOReader versions and devices are not yet
verified. Missing KOReader APIs make the plugin disable the affected feature
without interrupting reading.

## Install

1. Download `bookroom.koplugin.zip` and `bookroom.koplugin.zip.sha256` from the
   [latest release](https://github.com/joinbookroom/bookroom-koreader/releases/latest).
2. Optionally verify the archive:

   ```sh
   shasum -a 256 -c bookroom.koplugin.zip.sha256
   ```

   On systems with GNU coreutils, use `sha256sum -c` instead.
3. Connect your reader to your computer and open
   `.adds/koreader/plugins` on the device.
4. Extract the archive there. The resulting path must be
   `.adds/koreader/plugins/bookroom.koplugin/_meta.lua`.
5. Safely eject the device and restart KOReader.

For a repository checkout and a mounted Kobo, the safer verified installer is:

```sh
./scripts/install-plugin.sh /Volumes/KOBOeReader
```

It stages and verifies each replacement before activating it. The mount path
defaults to `/Volumes/KOBOeReader` when omitted.

### Update

Install the new release over `.adds/koreader/plugins/bookroom.koplugin`, safely
eject the device, and restart KOReader. Do not delete either of these settings
files:

- `.adds/koreader/settings/kosync.lua`
- `.adds/koreader/settings/bookroom_observations.lua`

The installer never writes to them.

## Connect to Book Room

1. In Book Room, open **Settings → Integrations → KOReader** and generate
   dedicated sync credentials.
2. In KOReader's **Progress Sync**, choose **Custom sync server** and enter
   `https://sync.joinbookroom.com` exactly, without a trailing slash.
3. Choose **Login** and enter the generated username and sync password.
4. Open an EPUB with a table of contents, then choose
   **Tools → More tools → Book Room → Send chapter now**.
5. Return to Book Room to confirm the book and chapter mapping before enabling
   automatic Book Room progress for that book.

Ordinary page turns inside one table-of-contents entry do not send another
request. Offline chapter changes retain only the latest pending observation per
document and are sent when KOReader reconnects.

## Privacy and data

The plugin sends data only to `https://sync.joinbookroom.com` over HTTPS. A
chapter observation contains:

- the dedicated KOSync username and KOReader's derived authentication key
  (`userkey`) in HTTPS authentication headers;
- the document digest, reader model/name, device ID, position, and percentage;
- the current table-of-contents entry and the normalized table-of-contents
  structure, including chapter titles and locations; and
- the plugin and payload versions.

It does **not** access or send book text, annotations, highlights, notes, or a
Book Room account password. It reads the existing KOSync credentials but never
displays, logs, changes, or copies the sync password into plugin storage.

KOReader stores the latest observation state locally in
`settings/bookroom_observations.lua`. That file can contain the KOSync username,
document digest, device details, reading position, percentage, and table of
contents, but not the sync password. It keeps at most one pending observation
per username and document. Removing that file clears pending and deduplication
state without changing KOSync credentials.

Book Room's own privacy policy and account controls apply after data reaches
the service.

## Development

The repository intentionally contains only the reader plugin, its tests, and
release tooling. The Book Room web application and KOSync-compatible backend
remain in the main Book Room repository.

Requirements for local checks:

- a POSIX shell;
- `texlua` and `texluac`;
- `zip`, `unzip`, `cmp`, and a SHA-256 tool.

Run the complete local suite:

```sh
./scripts/test-plugin.sh
```

Build and verify the release archive:

```sh
./scripts/package-plugin.sh
```

The archive and checksum are written to `dist/`. Packaging uses a fixed file
order and normalized timestamps, and verifies every archived file against the
tested source tree.

## Releases

Versions use semantic versioning and the plugin version is declared in both
`bookroom.koplugin/_meta.lua` and `bookroom.koplugin/main.lua`. The test suite
requires those values to match.

To publish a release:

1. update both version declarations and `CHANGELOG.md`;
2. run `./scripts/test-plugin.sh` and `./scripts/package-plugin.sh`;
3. commit the release, then create and push an annotated `vX.Y.Z` tag; and
4. push the generated `koreader-contrib` branch as described in
   [`CONTRIBUTING.md`](CONTRIBUTING.md).

Pushing the tag runs the release workflow, verifies that the tag matches the
plugin version, and creates a GitHub release containing the ZIP and SHA-256
checksum.

## License

Copyright © 2026 Book Room contributors.

This project is licensed under the GNU Affero General Public License v3.0.
See [`LICENSE`](LICENSE).
