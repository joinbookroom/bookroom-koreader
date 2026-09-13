# KOReader contrib submission

This directory contains a ready-to-apply patch for
[`koreader/contrib`](https://github.com/koreader/contrib). It adds Book Room as
a git submodule at `bookroom.koplugin`, following the contrib repository's
current requirements.

The submodule points to:

- repository: `https://github.com/anushkafka/bookroom-koreader.git`
- branch: `koreader-contrib`
- commit: `17e1689d0a09b96b0ba7f462a83af9d2663c8c20`

The `koreader-contrib` branch is generated from `bookroom.koplugin/` on this
repository's `main` branch, so `_meta.lua` and `main.lua` appear at the
submodule checkout root.

## Before submitting

1. Create the public `anushkafka/bookroom-koreader` GitHub repository.
2. Push both `main` and `koreader-contrib`.
3. Push the `v0.6.0` tag and confirm that the ZIP and checksum appear in the
   GitHub release.
4. Clone a fresh copy of `koreader/contrib`, apply the patch, and verify the
   submodule resolves:

   ```sh
   git am /path/to/0001-Add-Book-Room-plugin.patch
   git submodule update --init bookroom.koplugin
   test -f bookroom.koplugin/_meta.lua
   test -f bookroom.koplugin/main.lua
   ```

5. Open the upstream pull request using `PULL_REQUEST.md` as the description.

If the plugin branch changes before submission, regenerate this patch so its
gitlink pins the current tested `koreader-contrib` commit.
