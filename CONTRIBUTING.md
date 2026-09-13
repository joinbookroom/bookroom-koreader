# Contributing

Issues and pull requests are welcome. Keep changes scoped to the KOReader
plugin; server and web changes belong in the main Book Room repository.

Before opening a pull request, run:

```sh
./scripts/test-plugin.sh
./scripts/package-plugin.sh
```

Never commit `dist/`, device settings, credentials, document content, or real
reading data.

## Maintaining the KOReader contrib branch

The `main` branch keeps source, tests, and tooling together. KOReader's contrib
repository expects a submodule whose root contains `_meta.lua` and `main.lua`,
so the `koreader-contrib` branch contains only `bookroom.koplugin/`.

After committing a plugin change on `main`, regenerate and push that branch:

```sh
git subtree split --prefix=bookroom.koplugin -b koreader-contrib-next
git push origin koreader-contrib-next:koreader-contrib --force-with-lease
git branch -D koreader-contrib-next
```

The force update is intentional because `git subtree split` rebuilds the
branch. Do not develop directly on `koreader-contrib`.
