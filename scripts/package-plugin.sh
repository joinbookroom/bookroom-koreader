#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
plugin_dir="$integration_dir/bookroom.koplugin"
dist_dir="$integration_dir/dist"
archive="$dist_dir/bookroom.koplugin.zip"
web_download_dir="$integration_dir/../../apps/web/public/downloads"
web_archive="$web_download_dir/bookroom.koplugin.zip"

required_files="_meta.lua main.lua chapter.lua toc.lua kosync_credentials.lua docstate.lua client.lua observer.lua README.md"

for required_file in $required_files; do
    if [ ! -f "$plugin_dir/$required_file" ]; then
        echo "Missing plugin file: $required_file" >&2
        exit 1
    fi
done

mkdir -p "$dist_dir"
rm -f "$archive"

(
    cd "$integration_dir"
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

mkdir -p "$web_download_dir"
cp "$archive" "$web_archive"

if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive"
else
    sha256sum "$archive"
fi
