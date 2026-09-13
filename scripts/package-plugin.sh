#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
plugin_dir="$integration_dir/bookroom.koplugin"
dist_dir="$integration_dir/dist"
archive="$dist_dir/bookroom.koplugin.zip"
checksum="$archive.sha256"

required_files="_meta.lua main.lua chapter.lua toc.lua kosync_credentials.lua docstate.lua client.lua observer.lua README.md LICENSE"

for required_file in $required_files; do
    if [ ! -f "$plugin_dir/$required_file" ]; then
        echo "Missing plugin file: $required_file" >&2
        exit 1
    fi
done

mkdir -p "$dist_dir"
rm -f "$archive" "$checksum"

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/bookroom-package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
mkdir -p "$staging_dir/bookroom.koplugin"

for required_file in $required_files; do
    cp "$plugin_dir/$required_file" "$staging_dir/bookroom.koplugin/$required_file"
    # ZIP stores DOS timestamps. Fixing them makes artifacts reproducible
    # across fresh checkouts and release runners.
    touch -t 200001010000 "$staging_dir/bookroom.koplugin/$required_file"
done

(
    cd "$staging_dir"
    # A fixed file order and stripped ZIP metadata make repeated packages from
    # an unchanged source tree byte-for-byte identical.
    zip -X -q "$archive" $(for file in $required_files; do printf '%s ' "bookroom.koplugin/$file"; done)
)

# Do not publish a ZIP whose contents differ from the tested source tree.
for required_file in $required_files; do
    if ! unzip -p "$archive" "bookroom.koplugin/$required_file" \
        | cmp -s "$plugin_dir/$required_file" -; then
        echo "Packaged plugin verification failed: $required_file" >&2
        exit 1
    fi
done

if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$archive" | awk '{print $1}')
else
    digest=$(sha256sum "$archive" | awk '{print $1}')
fi

printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$checksum"
printf '%s  %s\n' "$digest" "$archive"
