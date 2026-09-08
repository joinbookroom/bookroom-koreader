local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Chapter = dofile(test_dir .. "/../bookroom.koplugin/chapter.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function reader(current_page, title_result)
    return {
        getCurrentPage = function()
            return current_page
        end,
        toc = {
            getTocTitleByPage = function(_, page)
                assertEqual(page, current_page, "TOC receives current location")
                return title_result
            end,
        },
    }
end

local chapter = Chapter.detect(reader(17, "  CHAPTER II  "))
assertEqual(chapter.status, "ok", "page-based chapter status")
assertEqual(chapter.title, "CHAPTER II", "chapter title is trimmed")
assertEqual(chapter.page, 17, "page is preserved")
assertEqual(chapter.pageType, "number", "page type is recorded")

local xpointer = "/body/DocFragment[3]/body/div/p[4]/text().216"
chapter = Chapter.detect(reader(xpointer, "Chapter 7"))
assertEqual(chapter.status, "ok", "position-based chapter status")
assertEqual(chapter.page, xpointer, "position is preserved")
assertEqual(chapter.pageType, "string", "position type is recorded")

chapter = Chapter.detect(reader(1, ""))
assertEqual(chapter.status, "unavailable", "empty title status")
assertEqual(chapter.reason, "no_toc_entry", "empty title reason")

chapter = Chapter.detect({})
assertEqual(chapter.status, "unavailable", "missing API status")
assertEqual(chapter.reason, "unsupported_api", "missing API reason")

chapter = Chapter.detect({
    getCurrentPage = function()
        error("page failed")
    end,
    toc = {
        getTocTitleByPage = function()
            return "unreachable"
        end,
    },
})
assertEqual(chapter.reason, "current_page_error", "current-page errors fail open")

chapter = Chapter.detect({
    getCurrentPage = function()
        return 4
    end,
    toc = {
        getTocTitleByPage = function()
            error("TOC failed")
        end,
    },
})
assertEqual(chapter.reason, "toc_error", "TOC errors fail open")

print("chapter extraction tests passed")
