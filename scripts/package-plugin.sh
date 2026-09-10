#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
plugin_dir="$integration_dir/bookroom.koplugin"
dist_dir="$integration_dir/dist"
archive="$dist_dir/bookroom.koplugin.zip"

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
zip -q -r "$archive" bookroom.koplugin -x '*/.DS_Store'
)

# Do not publish a ZIP whose contents differ from the tested source tree.
for required_file in $required_files; do
    if ! unzip -p "$archive" "bookroom.koplugin/$required_file" \
        | cmp -s "$plugin_dir/$required_file" -; then
        echo "Packaged plugin verification failed: $required_file" >&2
        exit 1
    fi
done

echo "$archive"
