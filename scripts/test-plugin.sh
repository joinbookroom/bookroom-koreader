#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
integration_dir=$(dirname "$script_dir")
plugin_dir="$integration_dir/bookroom.koplugin"

if ! command -v texluac >/dev/null 2>&1 || ! command -v texlua >/dev/null 2>&1; then
    echo "texlua and texluac are required to run the local plugin checks." >&2
    exit 1
fi

texluac -p \
    "$plugin_dir/_meta.lua" \
    "$plugin_dir/main.lua" \
    "$plugin_dir/chapter.lua" \
    "$plugin_dir/toc.lua" \
    "$plugin_dir/kosync_credentials.lua" \
    "$plugin_dir/kosync_document.lua" \
    "$plugin_dir/client.lua" \
    "$integration_dir/tests/chapter_test.lua" \
    "$integration_dir/tests/toc_test.lua" \
    "$integration_dir/tests/kosync_credentials_test.lua" \
    "$integration_dir/tests/kosync_document_test.lua" \
    "$integration_dir/tests/client_test.lua" \
    "$integration_dir/tests/menu_test.lua"

texlua "$integration_dir/tests/chapter_test.lua"
texlua "$integration_dir/tests/toc_test.lua"
texlua "$integration_dir/tests/kosync_credentials_test.lua"
texlua "$integration_dir/tests/kosync_document_test.lua"
texlua "$integration_dir/tests/client_test.lua"
texlua "$integration_dir/tests/menu_test.lua"
