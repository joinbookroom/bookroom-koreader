local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Toc = dofile(test_dir .. "/../bookroom.koplugin/toc.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function assertContains(value, expected, message)
    if not value:find(expected, 1, true) then
        error(string.format("%s: expected %q in %q", message, expected, value))
    end
end

local raw_toc = {
    { title = " Volume I ", depth = 1, page = 1, xpointer = "/body/volume1", seq_in_level = 1 },
    { title = "Chapter I", depth = 2, page = 4, xpointer = "/body/volume1/chapter1", seq_in_level = 1 },
    { title = "Chapter II", depth = 2, page = 11, xpointer = "/body/volume1/chapter2", seq_in_level = 2 },
    { title = "Volume II", depth = 1, page = 50, xpointer = "/body/volume2", seq_in_level = 2 },
    { title = "Chapter I", depth = 2, page = 54, xpointer = "/body/volume2/chapter1", seq_in_level = 1 },
    { title = "Part A", depth = 3, page = 55, xpointer = "/body/volume2/chapter1/part-a", seq_in_level = 1 },
}

local normalized, metadata = Toc.normalize(raw_toc)
assertEqual(#normalized, 6, "all source entries are retained")
assertEqual(metadata.sourceDepthBase, 1, "KOReader depth base is recorded")
assertEqual(normalized[1].index, 0, "indexes are zero-based")
assertEqual(normalized[1].title, "Volume I", "titles are conservatively trimmed")
assertEqual(normalized[1].depth, 0, "root depth is zero-based")
assertEqual(normalized[1].parentIndex, nil, "root has no parent")
assertEqual(normalized[2].parentIndex, 0, "child parent is derived")
assertEqual(normalized[3].parentIndex, 0, "sibling parent is derived")
assertEqual(normalized[5].parentIndex, 3, "repeated title uses structural parent")
assertEqual(normalized[6].parentIndex, 4, "nested parent is derived")
assertEqual(table.concat(normalized[6].path, " / "), "Volume II / Chapter I / Part A", "full path is retained")
assertEqual(normalized[5].page, 54, "page is retained")
assertEqual(normalized[5].sequenceInLevel, 1, "KOReader level sequence is retained")
assertEqual(normalized[5].location, "/body/volume2/chapter1", "xpointer becomes location")
assertEqual(raw_toc[1].title, " Volume I ", "KOReader source entry is not mutated")
assertEqual(raw_toc[2].parentIndex, nil, "derived fields are not added to KOReader entries")

local fill_calls = 0
local index_calls = 0
local toc_reader = {
    getCurrentPage = function()
        return "/body/volume2/chapter1/p.0"
    end,
    toc = {
        toc = raw_toc,
        toc_chapter_title_bind_to_ticks = true,
        fillToc = function(self)
            fill_calls = fill_calls + 1
            assertEqual(type(self.toc), "table", "ReaderToc cache remains available")
        end,
        getTocIndexByPage = function(_, location, skip_ignored_ticks)
            index_calls = index_calls + 1
            assertEqual(location, "/body/volume2/chapter1/p.0", "current location selects TOC entry")
            assertEqual(skip_ignored_ticks, true, "current-entry selection mirrors chapter-title settings")
            return 5
        end,
    },
}

local report = Toc.inspect(toc_reader)
assertEqual(report.status, "ok", "TOC inspection succeeds")
assertEqual(fill_calls, 1, "ReaderToc lazy fill is used")
assertEqual(index_calls, 1, "ReaderToc current-index API is used")
assertEqual(report.currentEntry.index, 4, "current entry is normalized")
assertEqual(report.currentEntry.parentIndex, 3, "current entry hierarchy is present")
assertEqual(#report.sample, 5, "diagnostic sample is bounded")

local observed = {}
for _, field in ipairs(report.observedRawFields) do
    observed[field.name] = field.types
end
assertEqual(observed.depth, "number", "raw depth field and type are reported")
assertEqual(observed.page, "number", "raw page field and type are reported")
assertEqual(observed.seq_in_level, "number", "ReaderToc-derived field is reported")
assertEqual(observed.title, "string", "raw title field and type are reported")
assertEqual(observed.xpointer, "string", "raw xpointer field and type are reported")

local diagnostics = Toc.formatDiagnostics(report, "Current chapter: Chapter I")
assertContains(diagnostics, "Current chapter: Chapter I", "diagnostic retains Step 3 chapter")
assertContains(diagnostics, "Raw fields observed across active ReaderToc.toc:", "diagnostic labels raw fields")
assertContains(diagnostics, "- xpointer (string)", "diagnostic shows raw field type")
assertContains(diagnostics, "[4] depth=1 parent=3 sequence=1 page=54", "diagnostic shows normalized current entry")
assertContains(diagnostics, "path: Volume II > Chapter I", "diagnostic shows normalized path")

local failed = Toc.inspect({
    getCurrentPage = function()
        return 1
    end,
    toc = {
        fillToc = function()
            error("TOC failed")
        end,
        getTocIndexByPage = function()
            return 1
        end,
    },
})
assertEqual(failed.status, "unavailable", "TOC failures fail open")
assertEqual(failed.reason, "toc_error", "TOC failure reason is retained")
local failure_text = Toc.formatDiagnostics(failed, "Current chapter: temporarily unavailable")
assertContains(failure_text, "TOC diagnostics unavailable: toc_error", "TOC failure can be displayed")

print("TOC normalization tests passed")
