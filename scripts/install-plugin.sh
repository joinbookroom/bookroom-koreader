#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
source_dir="$integration_dir/bookroom.koplugin"
volume=${1:-/Volumes/KOBOeReader}
plugins_dir="$volume/.adds/koreader/plugins"
target_dir="$plugins_dir/bookroom.koplugin"
temporary_file="$target_dir/BRINST.TMP"
# Supporting modules are activated first; the runtime entrypoint and metadata
# are last. Even an interrupted multi-file install therefore keeps the previous
# main.lua until all of its new dependencies have been verified.
required_files="chapter.lua toc.lua kosync_credentials.lua docstate.lua client.lua observer.lua README.md LICENSE main.lua _meta.lua"

if [ ! -d "$plugins_dir" ]; then
    echo "KOReader plugins directory not found: $plugins_dir" >&2
    echo "Mount the Kobo and pass its volume path as the first argument." >&2
    exit 1
fi

for required_file in $required_files; do
    if [ ! -f "$source_dir/$required_file" ]; then
        echo "Missing plugin source file: $required_file" >&2
        exit 1
    fi
done

mkdir -p "$target_dir"

cleanup() {
    rm -f "$temporary_file"
}
trap cleanup EXIT HUP INT TERM

# KOReader is stopped while the Kobo exports USB mass storage. Install each
# file through one FAT-safe temporary filename, verify it before activation,
# rename it over the destination, flush, and verify the live bytes again.
# If copying is interrupted before the rename, the previous live file remains.
for required_file in $required_files; do
    cp "$source_dir/$required_file" "$temporary_file"
    /bin/sync
    if ! cmp -s "$source_dir/$required_file" "$temporary_file"; then
        echo "Staged file verification failed: $required_file" >&2
        exit 1
    fi

    mv -f "$temporary_file" "$target_dir/$required_file"
    /bin/sync
    if ! cmp -s "$source_dir/$required_file" "$target_dir/$required_file"; then
        echo "Installed file verification failed: $required_file" >&2
        exit 1
    fi
done

/bin/sync
echo "Installed and verified Book Room at: $target_dir"
echo "Safely eject the Kobo before disconnecting it."
