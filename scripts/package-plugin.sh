#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
plugin_dir="$integration_dir/bookroom.koplugin"
dist_dir="$integration_dir/dist"
archive="$dist_dir/bookroom.koplugin.zip"

for required_file in _meta.lua main.lua chapter.lua toc.lua kosync_credentials.lua kosync_document.lua client.lua README.md; do
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

echo "$archive"
