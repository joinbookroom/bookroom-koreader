local Chapter = {}

local function unavailable(reason, detail)
    return {
        status = "unavailable",
        reason = reason,
        detail = detail,
    }
end

local function cleanTitle(title)
    if type(title) ~= "string" then
        return nil
    end

    local cleaned = title:gsub("^%s+", ""):gsub("%s+$", "")
    if cleaned == "" then
        return nil
    end
    return cleaned
end

-- Read only KOReader-owned public reader/TOC state. This module deliberately
-- has no settings, network, or Book Room server dependencies.
function Chapter.detect(ui)
    if type(ui) ~= "table" then
        return unavailable("reader_unavailable")
    end
    if type(ui.getCurrentPage) ~= "function" then
        return unavailable("unsupported_api", "ReaderUI:getCurrentPage is unavailable")
    end
    if type(ui.toc) ~= "table" or type(ui.toc.getTocTitleByPage) ~= "function" then
        return unavailable("unsupported_api", "ReaderToc:getTocTitleByPage is unavailable")
    end

    local page_ok, page_or_error = pcall(ui.getCurrentPage, ui)
    if not page_ok then
        return unavailable("current_page_error", tostring(page_or_error))
    end
    if type(page_or_error) ~= "number" and type(page_or_error) ~= "string" then
        return unavailable("current_page_unavailable")
    end

    local title_ok, title_or_error = pcall(
        ui.toc.getTocTitleByPage,
        ui.toc,
        page_or_error
    )
    if not title_ok then
        return unavailable("toc_error", tostring(title_or_error))
    end

    local title = cleanTitle(title_or_error)
    if not title then
        return unavailable("no_toc_entry")
    end

    return {
        status = "ok",
        title = title,
        page = page_or_error,
        pageType = type(page_or_error),
    }
end

return Chapter
