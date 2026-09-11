local Toc = {}

local SAMPLE_SIZE = 5
local MAX_VALUE_LENGTH = 180

local function unavailable(reason, detail)
    return {
        status = "unavailable",
        reason = reason,
        detail = detail,
    }
end

local function cleanTitle(title)
    if type(title) ~= "string" then
        return ""
    end
    return title:gsub("^%s+", ""):gsub("%s+$", "")
end

local function usableDepth(depth)
    if type(depth) ~= "number" or depth ~= depth then
        return nil
    end
    depth = math.floor(depth)
    if depth < 0 then
        return nil
    end
    return depth
end

local function optionalScalar(value)
    local value_type = type(value)
    if value_type == "number" or value_type == "string" then
        return value
    end
end

local function copyPath(path)
    local copied = {}
    if path then
        for i, title in ipairs(path) do
            copied[i] = title
        end
    end
    return copied
end

-- KOReader supplies a flat preorder TOC. Book Room keeps KOReader's stable
-- source position as a zero-based index and derives hierarchy without changing
-- the KOReader-owned objects.
function Toc.normalize(raw_toc)
    if type(raw_toc) ~= "table" then
        return nil, "TOC is not a table"
    end

    local source_depth_base
    for i = 1, #raw_toc do
        local raw_entry = raw_toc[i]
        local depth = type(raw_entry) == "table" and usableDepth(raw_entry.depth)
        if depth and (not source_depth_base or depth < source_depth_base) then
            source_depth_base = depth
        end
    end
    source_depth_base = source_depth_base or 1

    local normalized = {}
    local last_at_depth = {}

    for i = 1, #raw_toc do
        local raw_entry = type(raw_toc[i]) == "table" and raw_toc[i] or {}
        local source_depth = usableDepth(raw_entry.depth) or source_depth_base
        local depth = math.max(0, source_depth - source_depth_base)

        local parent
        for parent_depth = depth - 1, 0, -1 do
            if last_at_depth[parent_depth] then
                parent = last_at_depth[parent_depth]
                break
            end
        end

        local title = cleanTitle(raw_entry.title)
        local path = copyPath(parent and parent.path)
        table.insert(path, title)

        local entry = {
            index = i - 1,
            title = title,
            depth = depth,
            parentIndex = parent and parent.index or nil,
            path = path,
        }
        entry.page = optionalScalar(raw_entry.page)
        if type(raw_entry.seq_in_level) == "number" then
            entry.sequenceInLevel = raw_entry.seq_in_level
        end
        if type(raw_entry.xpointer) == "string" and raw_entry.xpointer ~= "" then
            entry.location = raw_entry.xpointer
        end

        normalized[i] = entry
        last_at_depth[depth] = entry
        for stale_depth in pairs(last_at_depth) do
            if stale_depth > depth then
                last_at_depth[stale_depth] = nil
            end
        end
    end

    return normalized, {
        sourceDepthBase = source_depth_base,
    }
end

local function compactValue(value)
    local value_type = type(value)
    if value_type == "string" then
        local compact = value:gsub("[\r\n\t]", " ")
        if #compact > MAX_VALUE_LENGTH then
            compact = compact:sub(1, MAX_VALUE_LENGTH - 3) .. "..."
        end
        return compact
    end
    if value_type == "number" or value_type == "boolean" or value_type == "nil" then
        return tostring(value)
    end
    return "<" .. value_type .. ">"
end

local function sortedKeys(entry)
    local keys = {}
    if type(entry) == "table" then
        for key in pairs(entry) do
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function describeEntry(entry)
    local fields = {}
    for _, key in ipairs(sortedKeys(entry)) do
        local value = entry[key]
        table.insert(fields, {
            name = tostring(key),
            type = type(value),
            value = compactValue(value),
        })
    end
    return fields
end

local function describeAllFields(raw_toc)
    local observed = {}
    for i = 1, #raw_toc do
        local entry = raw_toc[i]
        if type(entry) == "table" then
            for key, value in pairs(entry) do
                local name = tostring(key)
                observed[name] = observed[name] or {}
                observed[name][type(value)] = true
            end
        end
    end

    local names = {}
    for name in pairs(observed) do
        table.insert(names, name)
    end
    table.sort(names)

    local fields = {}
    for _, name in ipairs(names) do
        local types = {}
        for value_type in pairs(observed[name]) do
            table.insert(types, value_type)
        end
        table.sort(types)
        table.insert(fields, {
            name = name,
            types = table.concat(types, ", "),
        })
    end
    return fields
end

local function sampleBounds(count, current_index)
    if count <= SAMPLE_SIZE then
        return 1, count
    end

    local centre = current_index or 1
    local first = math.max(1, centre - math.floor(SAMPLE_SIZE / 2))
    local last = math.min(count, first + SAMPLE_SIZE - 1)
    first = math.max(1, last - SAMPLE_SIZE + 1)
    return first, last
end

-- Inspect the same validated TOC cache used by the active ReaderToc module.
-- fillToc() is KOReader's normal lazy-loading path and does not persist or send
-- anything outside the reader.
function Toc.inspect(ui)
    if type(ui) ~= "table" then
        return unavailable("reader_unavailable")
    end
    if type(ui.getCurrentPage) ~= "function" then
        return unavailable("unsupported_api", "ReaderUI:getCurrentPage is unavailable")
    end
    if type(ui.toc) ~= "table"
        or type(ui.toc.fillToc) ~= "function"
        or type(ui.toc.getTocIndexByPage) ~= "function" then
        return unavailable("unsupported_api", "ReaderToc TOC inspection APIs are unavailable")
    end

    local fill_ok, fill_error = pcall(ui.toc.fillToc, ui.toc)
    if not fill_ok then
        return unavailable("toc_error", tostring(fill_error))
    end
    local raw_toc = ui.toc.toc
    if type(raw_toc) ~= "table" then
        return unavailable("toc_error", "ReaderToc.toc is unavailable after fillToc")
    end
    if #raw_toc == 0 then
        return unavailable("no_toc_entries")
    end

    local normalize_ok, normalized, normalization = pcall(Toc.normalize, raw_toc)
    if not normalize_ok then
        return unavailable("normalization_error", tostring(normalized))
    end
    if type(normalized) ~= "table" then
        return unavailable("normalization_error", tostring(normalization))
    end

    local page_ok, current_page = pcall(ui.getCurrentPage, ui)
    if not page_ok then
        return unavailable("current_page_error", tostring(current_page))
    end
    if type(current_page) ~= "number" and type(current_page) ~= "string" then
        return unavailable("current_page_unavailable")
    end

    local index_ok, current_index = pcall(
        ui.toc.getTocIndexByPage,
        ui.toc,
        current_page,
        ui.toc.toc_chapter_title_bind_to_ticks
    )
    if not index_ok then
        return unavailable("toc_error", tostring(current_index))
    end
    if type(current_index) ~= "number" or not raw_toc[current_index] then
        current_index = nil
    end

    local sample_first, sample_last = sampleBounds(#normalized, current_index)
    local sample = {}
    for i = sample_first, sample_last do
        table.insert(sample, normalized[i])
    end

    return {
        status = "ok",
        currentPage = current_page,
        currentPageType = type(current_page),
        currentRawIndex = current_index,
        currentEntry = current_index and normalized[current_index] or nil,
        currentRawFields = current_index and describeEntry(raw_toc[current_index]) or {},
        observedRawFields = describeAllFields(raw_toc),
        entryCount = #normalized,
        entries = normalized,
        normalization = normalization,
        sample = sample,
        sampleFirstIndex = sample_first - 1,
        sampleLastIndex = sample_last - 1,
    }
end

local function displayOptional(value)
    if value == nil then
        return "null"
    end
    return compactValue(value)
end

local function appendNormalized(lines, entry, prefix)
    table.insert(lines, string.format(
        "%s[%d] depth=%d parent=%s sequence=%s page=%s",
        prefix or "",
        entry.index,
        entry.depth,
        displayOptional(entry.parentIndex),
        displayOptional(entry.sequenceInLevel),
        displayOptional(entry.page)
    ))
    table.insert(lines, "  title: " .. displayOptional(entry.title))
    table.insert(lines, "  path: " .. table.concat(entry.path, " > "))
    if entry.location then
        table.insert(lines, "  location: " .. compactValue(entry.location))
    end
end

function Toc.formatDiagnostics(report, chapter_text)
    local lines = {
        "Book Room Step 4 diagnostics (local only)",
        "",
        chapter_text,
    }

    if type(report) ~= "table" or report.status ~= "ok" then
        local reason = type(report) == "table" and report.reason or "plugin_error"
        table.insert(lines, "")
        table.insert(lines, "TOC diagnostics unavailable: " .. tostring(reason))
        if type(report) == "table" and report.detail then
            table.insert(lines, "Detail: " .. compactValue(report.detail))
        end
        return table.concat(lines, "\n")
    end

    table.insert(lines, "Current location (" .. report.currentPageType .. "): " .. compactValue(report.currentPage))
    table.insert(lines, "TOC entry count: " .. tostring(report.entryCount))
    table.insert(lines, "KOReader source depth base: " .. tostring(report.normalization.sourceDepthBase))
    table.insert(lines, "Book Room indexes/depths are zero-based.")

    table.insert(lines, "")
    table.insert(lines, "Raw fields observed across active ReaderToc.toc:")
    if #report.observedRawFields == 0 then
        table.insert(lines, "- none")
    else
        for _, field in ipairs(report.observedRawFields) do
            table.insert(lines, string.format("- %s (%s)", field.name, field.types))
        end
    end

    table.insert(lines, "")
    if report.currentRawIndex then
        table.insert(lines, "Current raw entry (Lua index " .. tostring(report.currentRawIndex) .. "):")
        for _, field in ipairs(report.currentRawFields) do
            table.insert(lines, string.format("- %s (%s) = %s", field.name, field.type, field.value))
        end
    else
        table.insert(lines, "Current raw entry: none at this location")
    end

    table.insert(lines, "")
    table.insert(lines, "Normalized current entry:")
    if report.currentEntry then
        appendNormalized(lines, report.currentEntry)
    else
        table.insert(lines, "none")
    end

    table.insert(lines, "")
    table.insert(lines, string.format(
        "Normalized sample (%d..%d):",
        report.sampleFirstIndex,
        report.sampleLastIndex
    ))
    for _, entry in ipairs(report.sample) do
        appendNormalized(lines, entry)
    end

    return table.concat(lines, "\n")
end

return Toc
